#!/usr/bin/env node
// Runs one unit of work on a coding CLI's ACP server and relays every permission request to a
// driver through files in a run directory. Usage: acp-worker.mjs launch|serve <run-dir>
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const TICK_MS = 250;
const CANCEL_GRACE_MS = 10_000;
const KILL_GRACE_MS = 5_000;
const CLOSE_WAIT_MS = 2_000;
const MAX_FOLLOW_UPS = 3;
const AUTH_ERROR = /auth|login|credential/i;

class Fail extends Error {
  constructor(kind, message) {
    super(message);
    this.kind = kind;
  }
}

class RpcError extends Error {
  constructor({ message = 'request failed', data } = {}) {
    const detail = [data?.message, data?.error].find((value) => typeof value === 'string');
    super(detail ? `${message}: ${detail}` : message);
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const shorten = (value) => JSON.stringify(value ?? null).slice(0, 300);
const options = (option) => (option?.options ?? []).flatMap((entry) => entry.options ?? [entry]);
const offers = (option, value) => options(option).some((entry) => entry.value === value);

class Worker {
  constructor(runDir) {
    this.runDir = runDir;
    this.nextId = 1;
    this.pending = new Map();
    this.stderrTail = [];
    this.configOptions = [];
    this.capabilities = {};
    this.models = null;
    this.modes = null;
    this.sessionId = '';
    this.initialized = false;
    this.ending = false;
    this.prompting = false;
    this.listening = false;
    this.buffer = '';
    this.freshBuffer = false;
    this.followUps = [];
    this.denied = [];
    this.stopReason = '';
    this.pendingAsk = null;
    this.askChain = Promise.resolve();
    this.forced = '';
    this.stopRequested = false;
    this.runningMs = 0;
    this.lastActivity = Date.now();
    this.lastTick = Date.now();
    this.aborted = new Promise((_, reject) => {
      this.abort = reject;
    });
    this.aborted.catch(() => {});
  }

  file(name) {
    return path.join(this.runDir, name);
  }

  write(name, content) {
    const temp = this.file(`.${name}.${process.pid}.tmp`);
    fs.writeFileSync(temp, content);
    fs.renameSync(temp, this.file(name));
  }

  log(line) {
    try {
      fs.appendFileSync(this.file('log'), `${new Date().toISOString()} ${line}\n`);
    } catch {
      // The driver removes the run dir once it has read the result, while shutdown still logs.
    }
  }

  setState(state) {
    this.write('state', state);
  }

  async execute() {
    this.write('pid', String(process.pid));
    for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => (this.stopRequested = true));
    let failure = null;
    try {
      const request = JSON.parse(fs.readFileSync(this.file('request.json'), 'utf8'));
      this.timeouts = {
        timeout: request.timeout ?? 1800,
        stall: request.stall ?? 300,
        askTimeout: request.askTimeout ?? 1800,
      };
      this.setState('running');
      this.ticker = setInterval(() => this.tick(), TICK_MS);
      await this.run(request);
    } catch (error) {
      failure = error instanceof Fail ? error : new Fail('run', error.message);
      this.log(`error (${failure.kind}): ${failure.message}`);
    }
    clearInterval(this.ticker);
    try {
      this.write(
        'result.json',
        JSON.stringify({
          session: this.sessionId,
          text: this.buffer,
          stopReason: this.stopReason,
          error: failure?.message ?? '',
          kind: failure?.kind ?? '',
          denied: this.denied,
        }),
      );
      this.setState(failure ? 'failed' : 'done');
    } catch {
      // The driver may have removed the run dir; the child must still be ended.
    }
    await this.shutdown();
  }

  async run(request) {
    this.startChild(request.command, request.cwd);
    await this.openSession(request);
    await this.selectMode(request.mode);
    await this.selectModel(request.model);
    const brief = this.readBrief(request.brief);
    this.listening = true;
    await this.converse([
      { type: 'text', text: request.message },
      { type: 'resource', resource: { uri: `file://${request.brief}`, mimeType: 'text/markdown', text: brief } },
    ]);
    if (this.stopReason !== 'end_turn') throw new Fail('run', `stopped: ${this.stopReason}`);
    if (!this.buffer.trim()) throw new Fail('run', 'no reply');
  }

  readBrief(briefPath) {
    try {
      return fs.readFileSync(briefPath, 'utf8');
    } catch (error) {
      throw new Fail('setup', `cannot read the brief: ${error.message}`);
    }
  }

  async converse(blocks) {
    await this.prompt(blocks);
    for (let count = 0; this.followUps.length && this.stopReason !== 'cancelled' && count < MAX_FOLLOW_UPS; count += 1) {
      this.freshBuffer = true;
      await this.prompt([{ type: 'text', text: this.followUps.splice(0).join('\n') }]);
    }
  }

  async prompt(blocks) {
    this.prompting = true;
    try {
      const result = await this.call('session/prompt', { sessionId: this.sessionId, prompt: blocks });
      this.stopReason = result.stopReason ?? '';
    } finally {
      this.prompting = false;
    }
    if (this.forced) throw new Fail('run', this.forced);
  }

  // Transport

  startChild(command, cwd) {
    const [executable, ...args] = command;
    const goneMessage = (code) => this.stderrTail.at(-1) || `${command.join(' ')} exited ${code}`;
    this.child = spawn(executable, args, {
      cwd,
      env: { ...process.env, LANE_MODE: 'unit' },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.on('error', (error) =>
      this.childGone(error.code === 'ENOENT' ? `${executable} not found` : error.message),
    );
    this.child.on('close', (code) => this.childGone(goneMessage(code)));
    this.child.stdin.on('error', () => {});
    readline.createInterface({ input: this.child.stdout }).on('line', (line) => this.onLine(line));
    readline.createInterface({ input: this.child.stderr }).on('line', (line) => {
      this.stderrTail.push(line);
      if (this.stderrTail.length > 20) this.stderrTail.shift();
    });
  }

  childGone(message) {
    if (this.ending) return;
    this.abort(new Fail(this.initialized ? 'run' : 'setup', message));
  }

  send(message) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
  }

  call(method, params) {
    const id = this.nextId++;
    this.log(`-> ${method} ${shorten(params)}`);
    const response = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject, method }));
    this.send({ id, method, params });
    return Promise.race([response, this.aborted]);
  }

  onLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.log(`ignored non-JSON line: ${line.slice(0, 200)}`);
      return;
    }
    if (message.method && message.id !== undefined) this.onRequest(message);
    else if (message.method) this.onNotification(message);
    else if (message.id !== undefined) this.onResponse(message);
  }

  onResponse({ id, result, error }) {
    const entry = this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id);
    this.lastActivity = Date.now();
    this.log(`<- ${entry.method} ${error ? `error ${shorten(error)}` : 'ok'}`);
    if (error) entry.reject(new RpcError(error));
    else entry.resolve(result ?? {});
  }

  onNotification({ method, params }) {
    if (method === 'session/update') this.onUpdate(params);
  }

  onUpdate({ sessionId, update }) {
    if (sessionId !== this.sessionId) return;
    this.lastActivity = Date.now();
    if (!this.listening) return;
    const kind = update?.sessionUpdate;
    if (kind === 'tool_call' || kind === 'tool_call_update') this.freshBuffer = true;
    else if (kind === 'agent_message_chunk' && update.content?.type === 'text') {
      if (this.freshBuffer) this.buffer = '';
      this.freshBuffer = false;
      this.buffer += update.content.text;
    }
  }

  onRequest(message) {
    if (message.method !== 'session/request_permission') {
      this.log(`rejected agent request ${message.method}`);
      this.send({ id: message.id, error: { code: -32601, message: 'Method not supported' } });
      return;
    }
    // One ask at a time: ask.json and answer.json hold a single pending ask.
    this.askChain = this.askChain
      .then(() => this.handlePermission(message.params))
      .then(
        (result) => this.send({ id: message.id, result }),
        (error) => this.send({ id: message.id, error: { code: -32603, message: error.message } }),
      );
  }

  // Session setup

  async setupCall(method, params) {
    try {
      return await this.call(method, params);
    } catch (error) {
      if (!(error instanceof RpcError)) throw error;
      throw new Fail(AUTH_ERROR.test(error.message) ? 'setup' : 'run', AUTH_ERROR.test(error.message) ? `not logged in: ${error.message}` : error.message);
    }
  }

  absorb(result) {
    if (result.configOptions) this.configOptions = result.configOptions;
    if (result.models) this.models = result.models;
    if (result.modes) this.modes = result.modes;
  }

  async openSession({ cwd, session }) {
    const init = await this.setupCall('initialize', {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    });
    this.initialized = true;
    this.capabilities = init.agentCapabilities ?? {};
    if (session) {
      this.sessionId = session;
      const method = this.capabilities.sessionCapabilities?.resume
        ? 'session/resume'
        : this.capabilities.loadSession && 'session/load';
      if (!method) throw new Fail('run', 'the agent cannot continue a session');
      this.absorb(await this.setupCall(method, { sessionId: session, cwd, mcpServers: [] }));
    } else {
      const created = await this.setupCall('session/new', { cwd, mcpServers: [] });
      this.sessionId = created.sessionId;
      this.absorb(created);
    }
    this.write('session', this.sessionId);
  }

  option(id) {
    return this.configOptions.find((option) => option.id === id);
  }

  async setConfig(configId, value) {
    const result = await this.call('session/set_config_option', { sessionId: this.sessionId, configId, value });
    if (result.configOptions) this.configOptions = result.configOptions;
  }

  async selectMode(mode) {
    if (!mode) return;
    if (offers(this.option('mode'), mode)) return this.setConfig('mode', mode);
    if (this.modes?.availableModes?.some((entry) => entry.id === mode)) {
      await this.call('session/set_mode', { sessionId: this.sessionId, modeId: mode });
      return undefined;
    }
    throw new Fail('setup', `mode ${mode} is not offered`);
  }

  async selectModel(model) {
    if (!model) return;
    if (offers(this.option('model'), model)) return this.setConfig('model', model);
    if (this.models?.availableModels?.some((entry) => entry.modelId === model)) {
      await this.call('session/set_model', { sessionId: this.sessionId, modelId: model });
      return undefined;
    }
    const level = this.configOptions.find((option) => option.category === 'thought_level');
    const base = options(this.option('model'))
      .map((entry) => entry.value)
      .filter((value) => model.startsWith(`${value}-`))
      .sort((a, b) => b.length - a.length)[0];
    if (base && offers(level, model.slice(base.length + 1))) {
      await this.setConfig('model', base);
      return this.setConfig(level.id, model.slice(base.length + 1));
    }
    throw new Fail('model', `Model unavailable: ${model}`);
  }

  // Permission asks

  async handlePermission({ toolCall = {}, options: choices = [] }) {
    if (this.forced) return { outcome: { outcome: 'cancelled' } };
    const ask = {
      id: `a${crypto.randomBytes(8).toString('hex')}`,
      title: toolCall.title ?? '',
      kind: toolCall.kind,
      rawInput: toolCall.rawInput,
      locations: toolCall.locations,
      options: choices,
    };
    // An answer file that already exists was not written for this ask.
    fs.rmSync(this.file('answer.json'), { force: true });
    this.write('ask.json', JSON.stringify(ask));
    this.setState('ask');
    this.log(`ask ${ask.id}: ${ask.title}`);
    const answer = await new Promise((resolve) => {
      this.pendingAsk = { ask, resolve, startedAt: Date.now() };
    });
    this.pendingAsk = null;
    const outcome = this.outcomeFor(ask, answer);
    this.log(`answer ${ask.id}: ${answer.decision} -> ${outcome.outcome} ${outcome.optionId ?? ''}`);
    fs.rmSync(this.file('ask.json'), { force: true });
    this.setState('running');
    this.lastActivity = Date.now();
    return { outcome };
  }

  outcomeFor(ask, answer) {
    if (answer.decision === 'stopped') return { outcome: 'cancelled' };
    if (answer.decision === 'once') {
      const allow = ask.options.find((entry) => entry.kind === 'allow_once');
      if (allow) return { outcome: 'selected', optionId: allow.optionId };
      this.log(`no allow_once option offered for ${ask.id}; rejecting`);
    }
    this.denied.push(ask.title);
    if (answer.decision === 'timeout') {
      this.followUps.push(`The coordinating session did not answer "${ask.title}" in time; continue without it.`);
    } else if (answer.message) {
      this.followUps.push(`The coordinating session refused "${ask.title}": ${answer.message}`);
    }
    const reject = ['reject_once', 'reject_always']
      .map((kind) => ask.options.find((entry) => entry.kind === kind))
      .find(Boolean);
    return reject ? { outcome: 'selected', optionId: reject.optionId } : { outcome: 'cancelled' };
  }

  checkAsk(now) {
    const { ask, resolve, startedAt } = this.pendingAsk;
    const answerFile = this.file('answer.json');
    if (fs.existsSync(answerFile)) {
      let answer = null;
      try {
        answer = JSON.parse(fs.readFileSync(answerFile, 'utf8'));
      } catch {
        // Possibly a half-written file: try again on the next tick.
      }
      if (answer) {
        fs.rmSync(answerFile, { force: true });
        if (answer.id === ask.id) return resolve({ decision: answer.decision, message: answer.message ?? '' });
        this.log(`ignored answer for ${answer.id}; waiting on ${ask.id}`);
      }
    }
    if (now - startedAt > this.timeouts.askTimeout * 1000) resolve({ decision: 'timeout' });
    return undefined;
  }

  // Timers

  tick() {
    const now = Date.now();
    const elapsed = now - this.lastTick;
    this.lastTick = now;
    if (this.forced) return;
    if (this.stopRequested || !fs.existsSync(this.runDir) || fs.existsSync(this.file('stop'))) return this.interrupt('stopped');
    if (this.pendingAsk) return this.checkAsk(now);
    this.runningMs += elapsed;
    const { stall, timeout } = this.timeouts;
    if (now - this.lastActivity > stall * 1000) {
      return this.interrupt(`printed nothing for ${stall}s (rate limited or stuck)`);
    }
    if (this.runningMs > timeout * 1000) return this.interrupt(`timed out after ${timeout}s`);
    return undefined;
  }

  interrupt(error) {
    this.forced = error;
    this.log(`interrupt: ${error}`);
    this.pendingAsk?.resolve({ decision: 'stopped' });
    if (!this.prompting) return this.abort(new Fail('run', error));
    this.send({ method: 'session/cancel', params: { sessionId: this.sessionId } });
    setTimeout(() => this.abort(new Fail('run', error)), CANCEL_GRACE_MS);
    return undefined;
  }

  // Shutdown

  async shutdown() {
    this.ending = true;
    const alive = () => this.child && this.child.exitCode === null && this.child.signalCode === null;
    if (alive() && this.sessionId && this.capabilities.sessionCapabilities?.close) {
      await Promise.race([this.call('session/close', { sessionId: this.sessionId }).catch(() => {}), sleep(CLOSE_WAIT_MS)]);
    }
    if (alive()) {
      const closed = new Promise((resolve) => this.child.once('close', resolve));
      this.child.kill('SIGTERM');
      await Promise.race([closed, sleep(KILL_GRACE_MS)]);
      if (alive()) this.child.kill('SIGKILL');
    }
    process.exit(0);
  }
}

function launch(runDir) {
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'serve', runDir], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  console.log(child.pid);
}

const [command, runDir] = process.argv.slice(2);
if (!runDir || !['launch', 'serve'].includes(command)) {
  console.error('usage: acp-worker.mjs launch|serve <run-dir>');
  process.exit(2);
}
if (command === 'launch') launch(path.resolve(runDir));
else await new Worker(path.resolve(runDir)).execute();
