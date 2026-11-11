#!/usr/bin/env node
// Persistent Pi stdio owner. No Pi internals or third-party runtime dependencies.
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SELF = fileURLToPath(import.meta.url);
const VERSION = 1;
const MAX_LINE = 64 * 1024 * 1024;
const REPLAY_BYTES = 4 * 1024 * 1024;
const MAX_SOCKET_BACKLOG = 8 * 1024 * 1024;
const SNAPSHOT_BYTES = 16 * 1024 * 1024;
const MAX_QUESTIONS = 256;
const largeWrites = new WeakMap();
const LOG_BYTES = 1024 * 1024;
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
// Unknown/EPERM is never absence and is never permission to launch a writer.
const alive = pid => !recordedPidAbsent(pid);
const canonical = file => fs.realpathSync(file);
function canonicalReference(file) {
  let current = path.resolve(file), suffix = [];
  for (;;) {
    try { return path.join(canonical(current), ...suffix); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      // A dangling symlink is not an authoritative identity for its old target.
      try { if (fs.lstatSync(current).isSymbolicLink()) throw new Error('Unresolved storage symlink'); }
      catch (statError) { if (statError.code !== 'ENOENT') throw statError; }
      const parent = path.dirname(current);
      if (parent === current) throw error;
      suffix.unshift(path.basename(current)); current = parent;
    }
  }
}
function launchResources(options) {
  if (!fs.statSync(options.cwd).isDirectory()) throw new Error('Historical restore requires an existing project directory');
  if (options.sessionFile && !fs.statSync(options.sessionFile).isFile()) throw new Error('Historical restore requires an existing session file');
}
function validateState(state, key) {
  const pid = value => value === null || (Number.isSafeInteger(value) && value > 0);
  if (!state || state.version !== VERSION || (state.key !== undefined && state.key !== key) ||
      !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(state.generation || '') || !/^[a-f0-9]{64}$/.test(state.token || '') ||
      !Number.isSafeInteger(state.bridgePid) || state.bridgePid <= 0 || !pid(state.piPid) ||
      !['starting', 'running', 'stopping', 'finished', 'exited', 'failed'].includes(state.status) ||
      typeof state.cwd !== 'string' || !path.isAbsolute(state.cwd) ||
      !(state.sessionFile === null || (typeof state.sessionFile === 'string' && path.isAbsolute(state.sessionFile)))) {
    throw new Error('Invalid runtime state; refusing another writer');
  }
  return state;
}
const encode = value => JSON.stringify(value) + '\n';

function privateDirectory(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      (process.getuid && stat.uid !== process.getuid()) || (stat.mode & 0o077)) {
    throw new Error(`Runtime directory must be owned by this user with mode 0700: ${dir}`);
  }
}
function readJSON(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024 ||
      (process.getuid && stat.uid !== process.getuid()) || (stat.mode & 0o077)) {
    throw new Error(`Unsafe runtime record: ${file}`);
  }
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}
function atomicJSON(file, data) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
  fs.writeFileSync(temporary, encode(data), { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}
function logChunk(file, bytes) {
  // Retain at most two bounded diagnostic segments; never let a noisy child fill disk.
  if (bytes.length > LOG_BYTES) bytes = bytes.subarray(-LOG_BYTES);
  const size = fs.existsSync(file) ? fs.statSync(file).size : 0;
  if (size + bytes.length > LOG_BYTES) {
    try { fs.renameSync(file, file + '.1'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  fs.appendFileSync(file, bytes, { mode: 0o600 });
}
function maybeJSON(file) {
  try { return readJSON(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
// Split only on LF, never on Unicode line/paragraph separators. Bound partial lines too.
export function lines(stream, onRecord, onError) {
  let buffer = Buffer.alloc(0), failed = false;
  const fail = error => { if (!failed) { failed = true; buffer = Buffer.alloc(0); onError(error); } };
  stream.on('data', chunk => {
    if (failed) return; // Keep draining, but never resynchronize an ambiguous command stream.
    try {
      buffer = Buffer.concat([buffer, Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)]);
      let index;
      while ((index = buffer.indexOf(10)) !== -1) {
        if (index > MAX_LINE) throw new Error('RPC record exceeds 64 MiB');
        const line = buffer.subarray(0, index).toString('utf8').replace(/\r$/, '');
        buffer = buffer.subarray(index + 1);
        if (line) onRecord(JSON.parse(line));
      }
      if (buffer.length > MAX_LINE) throw new Error('RPC partial record exceeds 64 MiB');
    } catch (error) { fail(error); }
  });
  stream.on('end', () => { if (buffer.length) fail(new Error('Incomplete final JSONL record')); });
}
function boundedWrite(stream, value) {
  const packet = encode(value), size = Buffer.byteLength(packet);
  const large = size > MAX_SOCKET_BACKLOG, outstanding = largeWrites.get(stream) || 0;
  // One frame up to the JSONL limit, plus 8 MiB of smaller queued frames.
  // A second large frame must wait for the first to drain; never retry writes.
  if (stream.destroyed || size > MAX_LINE || (large && outstanding) ||
      stream.writableLength + size > MAX_SOCKET_BACKLOG + Math.max(outstanding, large ? size : 0)) return false;
  if (large) largeWrites.set(stream, size);
  stream.write(packet, () => { if (large) largeWrites.delete(stream); });
  return true;
}
function send(socket, value) {
  if (boundedWrite(socket, value)) return true;
  socket.destroy(); return false;
}
function normalized(options) {
  if (process.platform === 'win32') throw new Error('Persistent bridge currently requires POSIX local sockets');
  if (!options || !Array.isArray(options.argv) || !options.argv.length ||
      options.argv.some(arg => typeof arg !== 'string' || arg.includes('\0'))) throw new Error('Invalid Pi argv');
  const root = canonicalReference(options.cwd);
  const runtime = path.resolve(options.runtime || path.join(os.homedir(), '.cache', 'emacs-pi', 'run'));
  privateDirectory(runtime);
  const file = options.sessionFile ? canonicalReference(options.sessionFile) : null;
  const identity = file ? `file:${file}` : `new:${options.id || crypto.randomUUID()}`;
  return { ...options, cwd: root, runtime, sessionFile: file, key: hash(identity).slice(0, 32) };
}
function paths(options) {
  const directory = path.join(options.runtime, options.key);
  return { directory, info: path.join(directory, 'state.json'), socket: path.join(directory, 'rpc.sock'),
    launch: path.join(directory, 'launch.json') };
}
export async function ensureInstance(raw) {
  const options = normalized(raw);
  // A new session acquires its authoritative file later. Discover that alias without cwd guessing.
  if (options.sessionFile) {
    const matches = [];
    for (const name of fs.readdirSync(options.runtime)) {
      if (!/^[a-f0-9]{32}$/.test(name)) continue;
      readonlyDirectory(path.join(options.runtime, name));
      const info = maybeJSON(path.join(options.runtime, name, 'state.json'));
      if (!info) {
        if (name !== options.key) throw new Error('Unindexed owner initializing or unknown; refusing another writer');
        continue;
      }
      validateState(info, name);
      const gone = ['finished', 'exited', 'failed'].includes(info.status) && recordedPidAbsent(info.bridgePid) && recordedPidAbsent(info.piPid);
      if (!gone && info.sessionFile === null) throw new Error('Unindexed owner may hold this history; refusing another writer');
      if (info.sessionFile === options.sessionFile && !gone) matches.push(name);
    }
    if (matches.length > 1) throw new Error('Multiple runtime owners claim this history; refusing ambiguous attach');
    if (matches.length) options.key = matches[0];
  }
  const p = paths(options);
  if (!fs.existsSync(p.directory)) launchResources(options);
  if (Buffer.byteLength(p.socket) > 100) throw new Error('Runtime socket path is too long; choose a shorter runtime directory');
  let owner = false;
  let launchGeneration = null;
  try { fs.mkdirSync(p.directory, { mode: 0o700 }); owner = true; }
  catch (error) { if (error.code !== 'EEXIST') throw error; privateDirectory(p.directory); }
  if (!owner) {
    const existing = maybeJSON(p.info);
    if (existing) validateState(existing, options.key);
    if (existing && ['starting', 'running', 'stopping'].includes(existing.status) &&
        !alive(existing.bridgePid)) {
      if (alive(existing.piPid)) throw new Error('Bridge owner lost but Pi may still run; refusing another writer');
      // Explicit historical open may replace a lost instance only when BOTH recorded PIDs are absent.
      existing.status = 'failed'; existing.error = 'Previous bridge and Pi exited unexpectedly';
      existing.ended = new Date().toISOString(); atomicJSON(p.info, existing);
    }
    if (existing && ['finished', 'exited', 'failed'].includes(existing.status)) {
      // Keep the prior outcome, but only recycle after its owner has actually exited.
      if (alive(existing.bridgePid) || alive(existing.piPid)) throw new Error('Previous bridge or Pi may still run; refusing another writer');
      launchResources(options);
      atomicJSON(path.join(p.directory, `previous-${existing.generation}.json`), existing);
      // Exclusive launch claim prevents concurrent historical restores.
      try { fs.mkdirSync(path.join(p.directory, 'launch-lock'), { mode: 0o700 }); owner = true; }
      catch { throw new Error('Instance launch already in progress'); }
    }
  }
  if (owner) {
    const config = { ...options, generation: crypto.randomUUID(), token: crypto.randomBytes(32).toString('hex') };
    launchGeneration = config.generation;
    atomicJSON(p.launch, config);
    const log = fs.openSync(path.join(p.directory, 'bridge.log'), 'a', 0o600);
    try {
      const child = spawn(process.execPath, [SELF, 'daemon', p.launch], {
        detached: true, stdio: ['ignore', log, log], cwd: options.cwd,
      });
      child.on('error', () => {});
      child.unref();
    } finally { fs.closeSync(log); }
  }
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const info = maybeJSON(p.info);
    if (info) validateState(info, options.key);
    if (owner && info && info.generation !== launchGeneration) { await delay(30); continue; }
    if (info && ['failed', 'finished', 'exited'].includes(info.status) && !owner) throw new Error(`Instance is ${info.status}`);
    if (info?.status === 'running' || info?.status === 'stopping') {
      if (info.cwd !== options.cwd) throw new Error('Instance working directory differs');
      if (options.sessionFile && info.sessionFile && info.sessionFile !== options.sessionFile) {
        throw new Error('Instance switched to a different session; refusing another writer');
      }
      if (!alive(info.bridgePid)) throw new Error('Bridge owner lost; inspect stale instance before historical recovery');
      return { ...p, ...info };
    }
    if (owner && info?.status === 'failed') throw new Error(info.error || 'Pi failed to launch');
    await delay(30);
  }
  throw new Error('Instance launch timed out; no automatic duplicate launch');
}

function publicRuntime(directory, state, status = state.status) {
  const field = (value, limit = 4096) => typeof value === 'string' && value.length <= limit ? value : null;
  return { instance: directory, generation: field(state.generation, 128),
    status, activity: ['finished', 'exited', 'failed'].includes(status) ? 'stopped' : 'unknown',
    sessionFile: field(state.sessionFile), sessionDirectory: field(state.sessionDirectory),
    sessionId: field(state.sessionId, 512), cwd: field(state.cwd),
    hasController: status === 'unknown' || typeof state.hasController !== 'boolean' ? null : state.hasController, persistent: true };
}
function recordedPidAbsent(pid) {
  if (pid === null) return true;
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return false; } catch (error) { return error.code === 'ESRCH'; }
}
function readonlyDirectory(directory) {
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) ||
      (process.getuid && info.uid !== process.getuid())) throw new Error('Unsafe runtime directory');
}
async function inspectRuntime(directory, state, timeout) {
  return new Promise(resolve => {
    const socket = net.createConnection(path.join(directory, 'rpc.sock'));
    let buffer = Buffer.alloc(0), done = false;
    const finish = value => {
      if (done) return;
      done = true; clearTimeout(timer); socket.destroy(); resolve(value);
    };
    const unknown = () => finish(publicRuntime(directory, state, 'unknown'));
    const timer = setTimeout(unknown, timeout);
    socket.on('error', unknown); socket.on('close', unknown);
    socket.on('connect', () => send(socket, { op: 'inspect', version: VERSION, token: state.token }));
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > 65536) { unknown(); return; }
      const newline = buffer.indexOf(10);
      if (newline < 0) return;
      try {
        const info = JSON.parse(buffer.subarray(0, newline));
        if (info.op !== 'info' || info.generation !== state.generation ||
            !['starting', 'running', 'stopping', 'finished', 'exited', 'failed'].includes(info.status)) { unknown(); return; }
        const uncertainExit = ['finished', 'exited', 'failed'].includes(info.status) && !recordedPidAbsent(info.piPid);
        finish(publicRuntime(directory, info, uncertainExit ? 'unknown' : info.status));
      } catch { unknown(); }
    });
  });
}
export async function inspectRuntimes(options = {}) {
  if (process.platform === 'win32') throw new Error('Runtime inspection requires POSIX local sockets');
  const runtime = path.resolve(options.runtime || path.join(os.homedir(), '.cache', 'emacs-pi', 'run'));
  if (!fs.existsSync(runtime)) return [];
  readonlyDirectory(runtime);
  const names = fs.readdirSync(runtime).filter(name => /^[a-f0-9]{32}$/.test(name));
  if (names.length > 512) throw new Error('Runtime inventory limit exceeded');
  const deadline = Date.now() + 2000, result = [];
  for (const name of names) {
    const directory = path.join(runtime, name);
    let state;
    if (Date.now() >= deadline) { result.push(publicRuntime(directory, {}, 'unknown')); continue; }
    try {
      readonlyDirectory(directory); state = readJSON(path.join(directory, 'state.json'));
      validateState(state, name);
    } catch { result.push(publicRuntime(directory, {}, 'unknown')); continue; }
    if (['finished', 'exited', 'failed'].includes(state.status) &&
        recordedPidAbsent(state.bridgePid) && recordedPidAbsent(state.piPid)) result.push(publicRuntime(directory, state));
    else if (Date.now() >= deadline) result.push(publicRuntime(directory, state, 'unknown'));
    else result.push(await inspectRuntime(directory, state, Math.max(1, Math.min(300, deadline - Date.now()))));
  }
  if (Buffer.byteLength(encode(result)) > 1024 * 1024) throw new Error('Runtime inventory output limit exceeded');
  return result;
}

async function daemon(configFile) {
  process.umask(0o077);
  const config = readJSON(configFile);
  const p = paths(config);
  fs.unlinkSync(configFile);
  let lease = null;
  let closing = false;
  let finishRequest = null;
  let finishTimer = null;
  let sequence = 0;
  let journal = [];
  let journalBytes = 0;
  let activeText = '';
  let activeTextTruncated = false;
  let activeTool = null;
  let latestQueue = null, queueBytes = 0, questionBytes = 0;
  let queueIncomplete = false, questionsIncomplete = false;
  const questions = new Map();
  const transactions = new Set();
  const state = { version: VERSION, generation: config.generation, token: config.token,
    bridgePid: process.pid, piPid: null, cwd: config.cwd, sessionFile: config.sessionFile,
    sessionId: null, sessionDirectory: config.argv.includes('--session-dir')
      ? path.resolve(config.cwd, config.argv[config.argv.indexOf('--session-dir') + 1]) : null,
    status: 'starting', started: new Date().toISOString() };
  const save = () => atomicJSON(p.info, state);
  save();
  const pi = spawn(config.argv[0], config.argv.slice(1), {
    cwd: config.cwd, stdio: ['pipe', 'pipe', 'pipe'],
  });
  pi.stderr.on('data', bytes => {
    try { logChunk(path.join(p.directory, 'pi-stderr.log'), bytes); }
    catch (error) { state.error = `Diagnostic log unavailable: ${error.message}`; }
  });
  state.piPid = pi.pid || null;
  const snapshot = () => ({ type: 'emacs_pi_bridge_state', generation: state.generation,
    instance: p.directory, activeText, activeTextTruncated, activeTool, queue: latestQueue,
    questions: [...questions.values()].map(item => item.value), status: state.status,
    recoveryIncomplete: queueIncomplete || questionsIncomplete, queueIncomplete, questionsIncomplete });
  const forgetQuestion = id => {
    const item = questions.get(id);
    if (item) { questionBytes -= item.bytes; questions.delete(id); }
  };
  const record = value => {
    const entry = { op: 'record', seq: ++sequence, record: value };
    const bytes = Buffer.byteLength(encode(entry));
    if (bytes <= REPLAY_BYTES) {
      journal.push({ entry, bytes }); journalBytes += bytes;
      while (journalBytes > REPLAY_BYTES) journalBytes -= journal.shift().bytes;
    } else { journal = []; journalBytes = 0; }
    if (lease) send(lease, entry);
  };
  const write = value => {
    if (!boundedWrite(pi.stdin, value)) throw new Error('Pi stdin unavailable or backpressured; command not resent');
  };
  const fail = error => {
    state.error = String(error.message || error);
    save();
    if (lease) send(lease, { op: 'error', error: state.error });
    // Protocol failure closes the input gracefully, never launches a replacement writer.
    closing = true; state.status = 'stopping'; save(); pi.stdin.end();
  };
  pi.stdin.on('error', error => { state.error = error.message; save(); });
  pi.on('error', error => { state.error = error.message; state.status = 'failed'; save(); });
  lines(pi.stdout, value => {
    if (value.type === 'response' && value.command === 'get_state' && value.success) {
      const data = value.data || {};
      if (typeof data.sessionFile === 'string' && path.isAbsolute(data.sessionFile)) {
        state.sessionFile = canonicalReference(data.sessionFile);
      }
      if (typeof data.sessionId === 'string') state.sessionId = data.sessionId;
      save();
    }
    if (value.id?.startsWith('__emacs_pi_bridge_')) return;
    if (value.type === 'message_start' && value.message?.role === 'assistant') { activeText = ''; activeTextTruncated = false; }
    if (value.type === 'message_update' && value.assistantMessageEvent?.type === 'text_delta') {
      activeText += value.assistantMessageEvent.delta || '';
      if (Buffer.byteLength(activeText) > REPLAY_BYTES) {
        // Keep the backend running; explicitly flag the incomplete transient preview.
        activeText = Buffer.from(activeText).subarray(-REPLAY_BYTES).toString('utf8');
        activeTextTruncated = true;
      }
    }
    if (value.type === 'message_end' && value.message?.role === 'assistant') { activeText = ''; activeTextTruncated = false; }
    if (value.type === 'tool_execution_start') activeTool = value.toolName;
    if (value.type === 'tool_execution_end') activeTool = null;
    if (value.type === 'queue_update') {
      const bytes = Buffer.byteLength(encode(value));
      queueIncomplete = questionBytes + bytes > SNAPSHOT_BYTES;
      latestQueue = queueIncomplete ? null : value; queueBytes = queueIncomplete ? 0 : bytes;
    }
    if (value.type === 'extension_ui_request' && ['select', 'confirm', 'input', 'editor'].includes(value.method)) {
      const bytes = Buffer.byteLength(encode(value)), old = questions.get(value.id);
      if (typeof value.id !== 'string' || value.id.length > 512 ||
          (!old && questions.size >= MAX_QUESTIONS) || questionBytes - (old?.bytes || 0) + queueBytes + bytes > SNAPSHOT_BYTES) {
        forgetQuestion(value.id); questionsIncomplete = true;
      } else {
        forgetQuestion(value.id); questions.set(value.id, {value, bytes}); questionBytes += bytes;
      }
    }
    if (value.type === 'agent_settled') { activeTool = null; questions.clear(); questionBytes = 0; questionsIncomplete = false; }
    if (value.type === 'response' && typeof value.id === 'string') transactions.delete(value.id);
    record(value);
    if ((value.type === 'extension_ui_request' || value.type === 'queue_update') && (queueIncomplete || questionsIncomplete)) {
      record({type:'emacs_pi_bridge_recovery_warning', recoveryIncomplete:true, queueIncomplete, questionsIncomplete});
    }
    // The history response and this snapshot share one stdout ordering boundary.
    if (value.type === 'response' && ['get_entries', 'get_messages'].includes(value.command)) record(snapshot());
  }, fail);
  const server = net.createServer(socket => {
    socket.on('error', () => {});
    let authorized = false;
    let attached = false;
    const timer = setTimeout(() => socket.destroy(), 5000);
    lines(socket, message => {
      try {
        if (!authorized) {
          if (message.token !== config.token || message.version !== VERSION) throw new Error('Bridge handshake rejected');
          authorized = true; clearTimeout(timer);
          if (message.op === 'inspect') { send(socket, { op: 'info', ...state, token: undefined, hasController: Boolean(lease) }); socket.end(); return; }
          if (message.op !== 'attach' || lease) throw new Error('Pi already has a controlling client');
          if (closing) throw new Error('Pi instance is stopping');
          lease = socket; attached = true;
          if (message.after !== undefined) {
            const after = message.after;
            if (!Number.isSafeInteger(after) || after < 0 || after > sequence) throw new Error('Invalid replay cursor');
            if (after < sequence && (!journal.length || after < journal[0].entry.seq - 1)) {
              send(socket, { op: 'resync', reason: 'Replay window exceeded; query state/history' });
            } else for (const item of journal) if (item.entry.seq > after) send(socket, item.entry);
          }
          send(socket, { op: 'ready', generation: state.generation, sequence, state: snapshot() });
          return;
        }
        if (!attached || lease !== socket) throw new Error('No controlling lease');
        if (message.op !== 'rpc' || typeof message.request?.type !== 'string') throw new Error('Invalid RPC envelope');
        const request = message.request;
        if (request.type.length > 128 || (request.id !== undefined && (typeof request.id !== 'string' || request.id.length > 512))) throw new Error('Invalid RPC identity');
        if (request.type === 'emacs_pi_finish') {
          if (closing) throw new Error('Finish already requested; outcome remains uncertain');
          closing = true; state.status = 'stopping'; save();
          finishRequest = { id: request.id, socket };
          // Refuse subsequent writes before clearing work and requesting orderly Pi disposal.
          try { write({ type: 'clear_queue', id: '__emacs_pi_bridge_clear' }); }
          catch { state.error = 'Finish requested; clearing the backpressured queue could not be confirmed'; save(); }
          // Even a refused clear must reach the bounded finish wait, not strand
          // the owner in stopping before its input is closed or timer is armed.
          pi.stdin.end();
          finishTimer = setTimeout(() => {
            if (finishRequest) send(socket, { op: 'record', seq: ++sequence, record: {
              type: 'response', command: 'emacs_pi_finish', id: request.id, success: false,
              error: 'Pi has not exited; instance remains stopping. No automatic force kill.',
            } });
            finishRequest = null;
          }, config.finishTimeout || 10000);
          return;
        }
        if (closing) throw new Error('Instance is stopping; command not sent');
        if (request.type === 'extension_ui_response' && !questions.has(request.id)) throw new Error('Question context is unavailable; reply not sent. No automatic approval or cancellation.');
        if (typeof request.id === 'string') {
          if (request.id.startsWith('__emacs_pi_bridge_') || transactions.has(request.id)) throw new Error('Duplicate or reserved request ID');
          if (request.type !== 'extension_ui_response') {
            if (transactions.size >= 256) throw new Error('Pending command limit reached; delivery not retried');
            transactions.add(request.id);
          }
        }
        write(request);
        if (request.type === 'extension_ui_response') forgetQuestion(request.id);
      } catch (error) { send(socket, { op: 'error', error: error.message }); socket.end(); }
    }, error => { send(socket, { op: 'error', error: error.message }); socket.destroy(); });
    socket.on('close', () => { clearTimeout(timer); if (lease === socket) lease = null; });
  });
  server.on('error', fail);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(p.socket, resolve);
  });
  state.status = pi.pid ? 'running' : 'failed'; save();
  try { fs.rmdirSync(path.join(p.directory, 'launch-lock')); } catch {}
  if (pi.pid) write({ type: 'get_state', id: '__emacs_pi_bridge_initial' });
  pi.on('close', (code, signal) => {
    clearTimeout(finishTimer);
    state.status = closing && !state.error ? 'finished' : code === 0 ? 'exited' : 'failed';
    state.exitCode = code; state.signal = signal; state.ended = new Date().toISOString(); save();
    if (finishRequest) {
      send(finishRequest.socket, { op: 'record', seq: ++sequence, record: {
        type: 'response', command: 'emacs_pi_finish', id: finishRequest.id,
        success: state.status === 'finished', data: { status: state.status }, error: state.error,
      } });
    }
    if (lease) lease.end();
    server.close();
    try { fs.unlinkSync(p.socket); } catch {}
    setTimeout(() => process.exit(code === 0 || state.status === 'finished' ? 0 : 1), 30);
  });
  // Catchable termination is orderly. SIGKILL/machine failure is reported as lost ownership on reconnect.
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { if (!closing) { closing = true; state.status = 'stopping'; save(); pi.stdin.end(); } });
}

export function attachInstance(options) {
  const runtime = path.resolve(options.runtime);
  readonlyDirectory(runtime);
  const key = path.basename(options.instance || '');
  if (!/^[a-f0-9]{32}$/.test(key) || path.resolve(options.instance) !== path.join(runtime, key)) throw new Error('Invalid attach identity');
  const p = paths({runtime, key}); readonlyDirectory(p.directory);
  const state = validateState(readJSON(p.info), key);
  if (state.generation !== options.generation || state.status !== 'running' ||
      state.sessionFile !== canonicalReference(options.sessionFile) || state.sessionId !== options.sessionId ||
      !alive(state.bridgePid)) throw new Error('Existing owner changed or unavailable; attach will not launch Pi');
  return {...p, ...state};
}

async function proxy(options, attachOnly = false) {
  const instance = attachOnly ? attachInstance(options) : await ensureInstance(options);
  const socket = net.createConnection(instance.socket);
  const queued = [];
  let queuedBytes = 0;
  let ready = false;
  let ending = false;
  const emit = record => {
    if (!process.stdout.write(encode(record))) { socket.pause(); process.stdout.once('drain', () => socket.resume()); }
  };
  const input = record => {
    if (ready) send(socket, { op: 'rpc', request: record });
    else {
      const size = Buffer.byteLength(encode(record));
      if (queued.length >= 100 || queuedBytes + size > MAX_SOCKET_BACKLOG) throw new Error('Client startup command limit exceeded');
      queuedBytes += size; queued.push(record);
    }
  };
  lines(process.stdin, input, error => { process.stderr.write(error.message + '\n'); socket.destroy(); process.exitCode = 1; });
  socket.on('connect', () => send(socket, { op: 'attach', version: VERSION, token: instance.token }));
  lines(socket, frame => {
    if (frame.op === 'ready') {
      ready = true; emit(frame.state); queuedBytes = 0;
      for (const request of queued.splice(0)) input(request);
    } else if (frame.op === 'record') emit(frame.record);
    else if (frame.op === 'error') { process.stderr.write(frame.error + '\n'); process.exitCode = 1; socket.end(); }
    else if (frame.op === 'resync') emit({ type: 'emacs_pi_bridge_resync', reason: frame.reason });
  }, error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; socket.destroy(); });
  socket.on('error', error => { process.stderr.write(`Bridge transport unavailable (no duplicate restart): ${error.message}\n`); process.exitCode = 1; });
  process.stdin.on('end', () => { ending = true; socket.end(); });
  socket.on('close', () => { process.stdin.destroy(); if (!ending) process.exitCode ||= 0; });
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { ending = true; socket.destroy(); process.stdin.destroy(); });
}

if (process.argv[1] && path.resolve(process.argv[1]) === SELF) {
  const [mode, argument] = process.argv.slice(2);
  const run = mode === 'inventory'
    ? inspectRuntimes(JSON.parse(Buffer.from(argument, 'base64url').toString('utf8'))).then(value => process.stdout.write(encode(value)))
    : mode === 'daemon' ? daemon(argument) : ['connect', 'attach'].includes(mode)
    ? proxy(JSON.parse(Buffer.from(argument, 'base64url').toString('utf8')), mode === 'attach')
    : Promise.reject(new Error('Usage: node emacs-pi-bridge.mjs connect BASE64URL_CONFIG'));
  run.catch(error => { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1; });
}
