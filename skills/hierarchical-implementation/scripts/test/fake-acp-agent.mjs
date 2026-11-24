#!/usr/bin/env node
// Stand-alone fake ACP agent on stdio for the acp-worker tests. Behaviour is chosen by FAKE_ACP_* env vars.
// FAKE_ACP_PIDFILE: if set, the agent writes its own pid there at startup.
// FAKE_ACP_CLOSE_DELAY_MS: delay the session/close reply by this many milliseconds.
// FAKE_ACP_ASK and FAKE_ACP_PARALLEL_ASKS list models whose prompt triggers one permission request, or two
// sent back to back without waiting (t1 "uname -a", t2 "id"); the turn ends once every reply has arrived.
// FAKE_ACP_ASK_COMMAND sets the first request's rawInput.command (default "uname -a").
// FAKE_ACP_ASK_TITLE sets the first request's title (default "uname -a"), including any newlines it holds.
import fs from 'node:fs';
import readline from 'node:readline';

const env = process.env;
const list = (name, fallback = '') => (env[name] ?? fallback).split(/\s+/).filter(Boolean);

const style = env.FAKE_ACP_STYLE || 'opencode';
const agy = style === 'agy';
const models = list('FAKE_ACP_MODELS', agy ? 'gemini-x-medium gemini-x-high' : 'opencode/a-free opencode/b-free opencode/c-free');
const configModes = list('FAKE_ACP_MODES', agy ? 'default auto plan' : 'build lane-worker');
const failModels = list('FAKE_ACP_FAIL');
const stallModels = list('FAKE_ACP_STALL');
const askModels = list('FAKE_ACP_ASK');
const parallelAskModels = list('FAKE_ACP_PARALLEL_ASKS');

if (env.FAKE_ACP_PIDFILE) fs.writeFileSync(env.FAKE_ACP_PIDFILE, String(process.pid));

const selected = { model: agy ? 'gemini-x' : models[0], level: '', mode: configModes[0] };
const sessions = new Map();
const waiting = new Map();
let nextRequestId = 1;

const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
const reply = (id, result) => send({ id, result });
const replyError = (id, code, message) => send({ id, error: { code, message } });
const record = (entry) => env.FAKE_ACP_LOG && fs.appendFileSync(env.FAKE_ACP_LOG, `${JSON.stringify(entry)}\n`);

const effectiveModel = () => (selected.level ? `${selected.model}-${selected.level}` : selected.model);

const selectOption = (id, category, current, values) => ({
  id,
  category,
  type: 'select',
  currentValue: current,
  options: values.map((value) => ({ value, name: value })),
});

function sessionShape() {
  if (!agy) {
    return {
      configOptions: [
        selectOption('model', 'model', selected.model, models),
        selectOption('mode', 'mode', selected.mode, configModes),
      ],
    };
  }
  return {
    configOptions: [
      selectOption('model', 'model', selected.model, ['gemini-x']),
      selectOption('thought_level', 'thought_level', selected.level || 'medium', ['low', 'medium', 'high']),
      selectOption('mode', 'mode', selected.mode, configModes),
    ],
    models: { availableModels: models.map((modelId) => ({ modelId })), currentModelId: models[0] },
    modes: {
      availableModes: [...configModes, 'accept-edits'].map((id) => ({ id })),
      currentModeId: selected.mode,
    },
  };
}

const update = (sessionId, body) => send({ method: 'session/update', params: { sessionId, update: body } });
const chunk = (sessionId, text) =>
  update(sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } });

const UNAME = {
  toolCallId: 't1',
  title: env.FAKE_ACP_ASK_TITLE || 'uname -a',
  kind: 'execute',
  rawInput: { command: env.FAKE_ACP_ASK_COMMAND || 'uname -a' },
  locations: [],
};
const ID = { toolCallId: 't2', title: 'id', kind: 'execute', rawInput: { command: 'id' }, locations: [] };

function askPermission(sessionId, toolCall = UNAME) {
  const id = `req-${nextRequestId++}`;
  send({
    id,
    method: 'session/request_permission',
    params: {
      sessionId,
      toolCall,
      options: [
        { optionId: 'once', kind: 'allow_once', name: 'Allow once' },
        { optionId: 'always', kind: 'allow_always', name: 'Always allow' },
        { optionId: 'reject', kind: 'reject_once', name: 'Reject' },
      ],
    },
  });
  return new Promise((resolve) => waiting.set(id, resolve));
}

function endTurn(session, stopReason) {
  const id = session.pending;
  session.pending = null;
  reply(id, { stopReason });
}

async function prompt(message) {
  const { sessionId } = message.params;
  const session = sessions.get(sessionId);
  session.prompts += 1;
  session.pending = message.id;
  const model = effectiveModel();

  if (session.prompts > 1) {
    chunk(sessionId, `followed up by ${model}`);
    return endTurn(session, 'end_turn');
  }
  if (failModels.includes(model)) {
    session.pending = null;
    return replyError(message.id, -32603, 'rate limited');
  }
  if (stallModels.includes(model)) return;

  if (parallelAskModels.includes(model)) {
    const answers = await Promise.all([askPermission(sessionId, UNAME), askPermission(sessionId, ID)]);
    if (session.pending !== message.id) return;
    answers.forEach((answer, index) => {
      const chosen = answer?.outcome?.optionId;
      update(sessionId, {
        sessionUpdate: 'tool_call_update',
        toolCallId: `t${index + 1}`,
        status: chosen === 'once' || chosen === 'always' ? 'completed' : 'failed',
      });
    });
  } else if (askModels.includes(model)) {
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 't1', title: 'uname -a', status: 'pending' });
    const answer = await askPermission(sessionId);
    if (session.pending !== message.id) return;
    const chosen = answer?.outcome?.optionId;
    update(sessionId, {
      sessionUpdate: 'tool_call_update',
      toolCallId: 't1',
      status: chosen === 'once' || chosen === 'always' ? 'completed' : 'failed',
    });
  } else {
    chunk(sessionId, 'narration');
    update(sessionId, { sessionUpdate: 'tool_call', toolCallId: 't1', title: 'ls', status: 'pending' });
  }
  chunk(sessionId, `done by ${model}`);
  endTurn(session, 'end_turn');
}

function openSession(message, sessionId) {
  if (!sessions.has(sessionId)) sessions.set(sessionId, { prompts: 0, pending: null });
  reply(message.id, { sessionId, ...sessionShape() });
}

function setConfig({ configId, value }) {
  if (configId === 'model') {
    selected.model = value;
    selected.level = '';
  } else if (configId === 'thought_level') selected.level = value;
  else if (configId === 'mode') selected.mode = value;
}

function handle(message) {
  const { id, method, params } = message;
  switch (method) {
    case 'initialize':
      return reply(id, {
        protocolVersion: 1,
        agentCapabilities: { loadSession: true, sessionCapabilities: { resume: {}, close: {} } },
      });
    case 'session/new':
      return openSession(message, 'fake-session-1');
    case 'session/resume':
    case 'session/load':
      return openSession(message, params.sessionId);
    case 'session/set_config_option':
      setConfig(params);
      return reply(id, { configOptions: sessionShape().configOptions });
    case 'session/set_mode':
      selected.mode = params.modeId;
      return reply(id, {});
    case 'session/set_model':
      selected.model = params.modelId;
      selected.level = '';
      return reply(id, {});
    case 'session/prompt':
      return prompt(message);
    case 'session/cancel': {
      const session = sessions.get(params.sessionId);
      if (session?.pending) endTurn(session, 'cancelled');
      return undefined;
    }
    case 'session/close':
      return void setTimeout(() => reply(id, {}), Number(env.FAKE_ACP_CLOSE_DELAY_MS) || 0);
    default:
      if (id !== undefined) replyError(id, -32601, 'Method not found');
      return undefined;
  }
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line);
  if (message.method) {
    record({ method: message.method, params: message.params });
    handle(message);
  } else if (waiting.has(message.id)) {
    record({ method: 'response', params: message.result });
    waiting.get(message.id)(message.result);
    waiting.delete(message.id);
  }
});
