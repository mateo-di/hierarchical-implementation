import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const worker = path.join(here, 'acp-worker.mjs');
const fakeAgent = path.join(here, 'test', 'fake-acp-agent.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'acp-worker-test-'));
const children = [];

after(() => {
  for (const child of children) child.kill('SIGKILL');
  fs.rmSync(root, { recursive: true, force: true });
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(check, ms = 15000) {
  const end = Date.now() + ms;
  for (;;) {
    const value = check();
    if (value) return value;
    if (Date.now() > end) throw new Error('timed out waiting for a condition');
    await sleep(50);
  }
}

function setup(overrides = {}, env = {}) {
  const dir = fs.mkdtempSync(path.join(root, 'run-'));
  const brief = path.join(dir, 'brief.md');
  fs.writeFileSync(brief, '# Brief\nDo the thing.\n');
  const request = {
    command: [process.execPath, fakeAgent],
    cwd: dir,
    model: 'opencode/b-free',
    mode: 'lane-worker',
    brief,
    message: 'Execute the unit.',
    session: '',
    timeout: 60,
    stall: 60,
    askTimeout: 60,
    ...overrides,
  };
  fs.writeFileSync(path.join(dir, 'request.json'), JSON.stringify(request));
  const logFile = path.join(dir, 'agent-log.jsonl');
  return { dir, brief, logFile, env: { ...env, FAKE_ACP_LOG: logFile } };
}

function serve(run) {
  const child = spawn(process.execPath, [worker, 'serve', run.dir], {
    env: { ...process.env, ...run.env },
    stdio: 'ignore',
  });
  children.push(child);
  return new Promise((resolve) => child.on('exit', resolve));
}

const read = (run, name) => fs.readFileSync(path.join(run.dir, name), 'utf8');
const readJson = (run, name) => JSON.parse(read(run, name));
const exists = (run, name) => fs.existsSync(path.join(run.dir, name));
const stateOf = (run) => (exists(run, 'state') ? read(run, 'state') : '');
const agentCalls = (run) =>
  exists(run, 'agent-log.jsonl')
    ? read(run, 'agent-log.jsonl').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
    : [];
const callsTo = (run, method) => agentCalls(run).filter((call) => call.method === method);

async function runToEnd(overrides, env) {
  const run = setup(overrides, env);
  assert.equal(await serve(run), 0);
  return { run, result: readJson(run, 'result.json') };
}

test('a plain run ends done with the last message and the session', async () => {
  const { run, result } = await runToEnd();
  assert.equal(read(run, 'state'), 'done');
  assert.equal(result.text, 'done by opencode/b-free');
  assert.equal(result.error, '');
  assert.equal(result.kind, '');
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(result.session, 'fake-session-1');
  assert.equal(read(run, 'session'), 'fake-session-1');
  assert.equal(read(run, 'pid').length > 0, true);
  const [prompt] = callsTo(run, 'session/prompt');
  assert.equal(prompt.params.prompt[0].text, 'Execute the unit.');
  assert.equal(prompt.params.prompt[1].resource.uri, `file://${run.brief}`);
  assert.match(prompt.params.prompt[1].resource.text, /Do the thing/);
});

test('opencode style selects mode then model with set_config_option', async () => {
  const { run } = await runToEnd();
  const sets = callsTo(run, 'session/set_config_option').map((call) => [call.params.configId, call.params.value]);
  assert.deepEqual(sets, [['mode', 'lane-worker'], ['model', 'opencode/b-free']]);
});

test('agy style selects through set_mode and set_model', async () => {
  const { run, result } = await runToEnd(
    { model: 'gemini-x-high', mode: 'accept-edits' },
    { FAKE_ACP_STYLE: 'agy' },
  );
  assert.equal(result.text, 'done by gemini-x-high');
  assert.equal(callsTo(run, 'session/set_mode')[0].params.modeId, 'accept-edits');
  assert.equal(callsTo(run, 'session/set_model')[0].params.modelId, 'gemini-x-high');
});

test('agy style selects a base model plus level', async () => {
  const { run, result } = await runToEnd({ model: 'gemini-x-low', mode: 'auto' }, { FAKE_ACP_STYLE: 'agy' });
  assert.equal(result.text, 'done by gemini-x-low');
  const sets = callsTo(run, 'session/set_config_option').map((call) => [call.params.configId, call.params.value]);
  assert.deepEqual(sets, [['mode', 'auto'], ['model', 'gemini-x'], ['thought_level', 'low']]);
});

test('a missing mode fails as setup', async () => {
  const { run, result } = await runToEnd({ mode: 'nope' });
  assert.equal(read(run, 'state'), 'failed');
  assert.equal(result.kind, 'setup');
  assert.equal(result.error, 'mode nope is not offered');
});

test('a missing model fails as model', async () => {
  const { result } = await runToEnd({ model: 'opencode/missing' });
  assert.equal(result.kind, 'model');
  assert.equal(result.error, 'Model unavailable: opencode/missing');
});

test('a missing command fails as setup', async () => {
  const { result } = await runToEnd({ command: ['definitely-not-a-cli', 'acp'] });
  assert.equal(result.kind, 'setup');
  assert.equal(result.error, 'definitely-not-a-cli not found');
});

test('a prompt error fails as run with the message', async () => {
  const { result } = await runToEnd({}, { FAKE_ACP_FAIL: 'opencode/b-free' });
  assert.equal(result.kind, 'run');
  assert.equal(result.error, 'rate limited');
});

test('an ask answered once selects the allow_once option and finishes', async () => {
  const run = setup({}, { FAKE_ACP_ASK: 'opencode/b-free' });
  const ended = serve(run);
  await until(() => stateOf(run) === 'ask' && exists(run, 'ask.json'));
  const ask = readJson(run, 'ask.json');
  assert.match(ask.id, /^a[0-9a-f]{16}$/);
  assert.equal(ask.title, 'uname -a');
  assert.equal(ask.kind, 'execute');
  assert.deepEqual(ask.rawInput, { command: 'uname -a' });
  assert.equal(ask.options.length, 3);

  fs.writeFileSync(path.join(run.dir, 'answer.json'), JSON.stringify({ id: 'zz', decision: 'once' }));
  await until(() => !exists(run, 'answer.json'));
  assert.equal(stateOf(run), 'ask');

  fs.writeFileSync(path.join(run.dir, 'answer.json'), JSON.stringify({ id: ask.id, decision: 'once' }));
  assert.equal(await ended, 0);
  const result = readJson(run, 'result.json');
  assert.equal(read(run, 'state'), 'done');
  assert.equal(result.text, 'done by opencode/b-free');
  assert.deepEqual(result.denied, []);
  assert.equal(exists(run, 'ask.json'), false);
  assert.equal(exists(run, 'answer.json'), false);
  assert.equal(callsTo(run, 'response')[0].params.outcome.optionId, 'once');
});

test('a rejected ask is listed as denied and its message is sent as a follow-up', async () => {
  const run = setup({}, { FAKE_ACP_ASK: 'opencode/b-free' });
  const ended = serve(run);
  await until(() => stateOf(run) === 'ask' && exists(run, 'ask.json'));
  fs.writeFileSync(
    path.join(run.dir, 'answer.json'),
    JSON.stringify({ id: readJson(run, 'ask.json').id, decision: 'reject', message: 'no shell here' }),
  );
  assert.equal(await ended, 0);
  const result = readJson(run, 'result.json');
  assert.equal(callsTo(run, 'response')[0].params.outcome.optionId, 'reject');
  assert.deepEqual(result.denied, ['uname -a']);
  const prompts = callsTo(run, 'session/prompt');
  assert.equal(prompts.length, 2);
  assert.equal(prompts[1].params.prompt[0].text, 'The coordinating session refused "uname -a": no shell here');
  assert.equal(result.text, 'followed up by opencode/b-free');
  assert.equal(result.error, '');
});

test('an unanswered ask is rejected after askTimeout', async () => {
  const { run, result } = await runToEnd({ askTimeout: 1 }, { FAKE_ACP_ASK: 'opencode/b-free' });
  assert.equal(callsTo(run, 'response')[0].params.outcome.optionId, 'reject');
  assert.deepEqual(result.denied, ['uname -a']);
  const prompts = callsTo(run, 'session/prompt');
  assert.match(prompts[1].params.prompt[0].text, /did not answer "uname -a" in time/);
  assert.equal(read(run, 'state'), 'done');
});

test('a silent agent fails with the stall message', async () => {
  const { run, result } = await runToEnd({ stall: 1 }, { FAKE_ACP_STALL: 'opencode/b-free' });
  assert.equal(read(run, 'state'), 'failed');
  assert.equal(result.kind, 'run');
  assert.equal(result.error, 'printed nothing for 1s (rate limited or stuck)');
  assert.equal(callsTo(run, 'session/cancel').length, 1);
});

test('a stop file stops the run', async () => {
  const run = setup({}, { FAKE_ACP_STALL: 'opencode/b-free' });
  const ended = serve(run);
  await until(() => callsTo(run, 'session/prompt').length === 1);
  fs.writeFileSync(path.join(run.dir, 'stop'), '');
  assert.equal(await ended, 0);
  const result = readJson(run, 'result.json');
  assert.equal(read(run, 'state'), 'failed');
  assert.equal(result.error, 'stopped');
  assert.equal(result.kind, 'run');
});

test('launch returns while the detached serve keeps running and finishes', async () => {
  const run = setup({}, { FAKE_ACP_ASK: 'opencode/b-free' });
  const pid = execFileSync(process.execPath, [worker, 'launch', run.dir], {
    env: { ...process.env, ...run.env },
    encoding: 'utf8',
  }).trim();
  assert.match(pid, /^\d+$/);
  await until(() => stateOf(run) === 'ask' && exists(run, 'ask.json'));
  assert.equal(read(run, 'pid'), pid);
  process.kill(Number(pid), 0);
  fs.writeFileSync(path.join(run.dir, 'answer.json'), JSON.stringify({ id: readJson(run, 'ask.json').id, decision: 'once' }));
  await until(() => stateOf(run) === 'done');
  assert.equal(readJson(run, 'result.json').text, 'done by opencode/b-free');
});

test('a session id resumes the session', async () => {
  const { run, result } = await runToEnd({ session: 'earlier-session' });
  assert.equal(callsTo(run, 'session/new').length, 0);
  assert.equal(callsTo(run, 'session/resume')[0].params.sessionId, 'earlier-session');
  assert.equal(callsTo(run, 'session/prompt')[0].params.sessionId, 'earlier-session');
  assert.equal(result.session, 'earlier-session');
  assert.equal(read(run, 'state'), 'done');
});

const answer = (run, body) => fs.writeFileSync(path.join(run.dir, 'answer.json'), JSON.stringify(body));
const pendingAskTitle = (run, title) =>
  stateOf(run) === 'ask' && exists(run, 'ask.json') && readJson(run, 'ask.json').title === title;

test('parallel asks are shown and answered one at a time', async () => {
  const run = setup({}, { FAKE_ACP_PARALLEL_ASKS: 'opencode/b-free' });
  const ended = serve(run);
  await until(() => pendingAskTitle(run, 'uname -a'));
  const first = readJson(run, 'ask.json').id;
  answer(run, { id: first, decision: 'once' });
  await until(() => pendingAskTitle(run, 'id'));
  const second = readJson(run, 'ask.json').id;
  assert.notEqual(second, first);
  answer(run, { id: second, decision: 'reject' });
  assert.equal(await ended, 0);
  const result = readJson(run, 'result.json');
  assert.equal(read(run, 'state'), 'done');
  assert.deepEqual(result.denied, ['id']);
  assert.deepEqual(callsTo(run, 'response').map((call) => call.params.outcome.optionId), ['once', 'reject']);
});

test('a stop while an ask is pending cancels it and the queued ask', async () => {
  const run = setup({}, { FAKE_ACP_PARALLEL_ASKS: 'opencode/b-free' });
  const ended = serve(run);
  await until(() => pendingAskTitle(run, 'uname -a'));
  await until(() => callsTo(run, 'session/prompt').length === 1);
  fs.writeFileSync(path.join(run.dir, 'stop'), '');
  assert.equal(await ended, 0);
  const result = readJson(run, 'result.json');
  assert.equal(result.error, 'stopped');
  assert.deepEqual(result.denied, []);
  assert.deepEqual(callsTo(run, 'response').map((call) => call.params.outcome.outcome), ['cancelled', 'cancelled']);
  assert.equal(/ ask a[0-9a-f]{16}: id$/m.test(read(run, 'log')), false);
});

test('the agent process still ends when the run dir is removed after done', async () => {
  const pidFile = path.join(root, `agent-${Date.now()}.pid`);
  const run = setup({}, { FAKE_ACP_PIDFILE: pidFile, FAKE_ACP_CLOSE_DELAY_MS: '500' });
  const ended = serve(run);
  await until(() => stateOf(run) === 'done');
  fs.rmSync(run.dir, { recursive: true, force: true });
  assert.equal(await ended, 0);
  const agentPid = Number(fs.readFileSync(pidFile, 'utf8'));
  const alive = () => {
    try {
      process.kill(agentPid, 0);
      return true;
    } catch {
      return false;
    }
  };
  await until(() => !alive(), 10000);
});

test('an answer file written before the ask appears is not used', async () => {
  const run = setup({}, { FAKE_ACP_ASK: 'opencode/b-free' });
  fs.writeFileSync(path.join(run.dir, 'answer.json'), JSON.stringify({ id: 'a1', decision: 'once' }));
  const ended = serve(run);
  await until(() => stateOf(run) === 'ask' && exists(run, 'ask.json'));
  assert.equal(exists(run, 'answer.json'), false);
  await sleep(1000);
  assert.equal(stateOf(run), 'ask');
  answer(run, { id: readJson(run, 'ask.json').id, decision: 'once' });
  assert.equal(await ended, 0);
  assert.equal(read(run, 'state'), 'done');
});

test('the agent process still ends when the run dir is gone before the result is written', async () => {
  const pidFile = path.join(root, `agent-early-${Date.now()}.pid`);
  const run = setup({}, { FAKE_ACP_PIDFILE: pidFile, FAKE_ACP_ASK: 'opencode/b-free' });
  const ended = serve(run);
  await until(() => stateOf(run) === 'ask' && exists(run, 'ask.json'));
  const askId = readJson(run, 'ask.json').id;
  const removedAt = Date.now();
  fs.rmSync(run.dir, { recursive: true, force: true });
  assert.equal(await ended, 0, 'the worker exits cleanly');
  assert.ok(Date.now() - removedAt < 10000, 'the worker treats a missing run dir as a stop');
  const agentPid = Number(fs.readFileSync(pidFile, 'utf8'));
  await until(() => {
    try {
      process.kill(agentPid, 0);
      return false;
    } catch {
      return true;
    }
  }, 10000);
  assert.match(askId, /^a[0-9a-f]{16}$/);
});
