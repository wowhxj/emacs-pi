import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { ensureInstance, attachInstance, inspectRuntimes, lines } from '../emacs-pi-bridge.mjs';

const bridge = fileURLToPath(new URL('../emacs-pi-bridge.mjs', import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, timeout = 8000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const value = predicate(); if (value) return value; await sleep(20); }
  throw new Error('Timed out waiting for test condition');
}
function fixture() {
  const dir = fs.mkdtempSync('/tmp/pi-b-');
  fs.chmodSync(dir, 0o700);
  const sessionFile = path.join(dir, 's.jsonl');
  fs.writeFileSync(sessionFile, '{}\n');
  const fake = path.join(dir, 'fake.mjs');
  fs.writeFileSync(fake, `import fs from 'node:fs';
let pending = '', timer;
const output = record => process.stdout.write(JSON.stringify(record)+'\\n');
process.stdin.on('data', bytes => {
 pending += bytes.toString(); let i;
 while ((i=pending.indexOf('\\n'))!==-1) {
  const r=JSON.parse(pending.slice(0,i)); pending=pending.slice(i+1);
  if (r.type==='get_state') output({type:'response',id:r.id,command:r.type,success:true,data:{sessionId:'test-session',sessionFile:${JSON.stringify(sessionFile)},pid:process.pid,isStreaming:!!timer}});
  else if(r.type==='work') { output({type:'work_accepted',id:r.id}); timer=setTimeout(()=>{
    output({type:'message_start',message:{role:'assistant'}});
    output({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'x'.repeat(1024*1024)}});
    fs.writeFileSync(${JSON.stringify(path.join(dir, 'done'))},'done');
    output({type:'response',id:r.id,command:r.type,success:true,data:{completed:true}});timer=null;
  },500); }
  else if(r.type==='exit') { output({type:'response',id:r.id,command:r.type,success:true}); setTimeout(()=>process.exit(0),20); }
  else if(r.type==='question') output({type:'extension_ui_request',id:'question-1',method:'confirm',title:'Do not auto approve'});
  else if(r.type==='big_echo') output({type:'response',id:r.id,command:r.type,success:true,data:{size:r.payload.length}});
  else if(r.type==='large_question') output({type:'extension_ui_request',id:r.questionId||'question-big',method:'editor',title:'large context',text:'q'.repeat(r.bytes)});
  else if(r.type==='big_queue') output({type:'queue_update',steering:[],followUp:r.bytes?['q'.repeat(r.bytes)]:[]});
  else if(r.type==='many_questions') {for(let n=0;n<257;n++) output({type:'extension_ui_request',id:'q-'+n,method:'confirm',title:'context-'+n});}
  else if(r.type==='extension_ui_response') {fs.writeFileSync(${JSON.stringify(path.join(dir, 'replies'))},r.id);}
  else if(r.type==='hold') {}
  else if(r.type==='flood') {
    output({type:'message_start',message:{role:'assistant'}});
    for(let n=0;n<48;n++) output({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'z'.repeat(1024*1024)}});
    process.stdout.write(JSON.stringify({type:'response',id:r.id,command:'flood',success:true})+'\\n',()=>fs.writeFileSync(${JSON.stringify(path.join(dir, 'flood.done'))},'done'));
  }
  else if(r.type==='clear_queue') {clearTimeout(timer);timer=null;}
  else output({type:'response',id:r.id,command:r.type,success:true,data:{entries:[],leafId:null}});
 }
});
process.stdin.on('end',()=>{clearTimeout(timer);process.exit(0)});
`);
  return { dir, options: { runtime: path.join(dir, 'run'), cwd: dir, sessionFile,
    argv: [process.execPath, fake], finishTimeout: 2000 } };
}
function client(options) {
  const child = spawn(process.execPath, [bridge, 'connect', Buffer.from(JSON.stringify(options)).toString('base64url')], { stdio: ['pipe', 'pipe', 'pipe'] });
  const records = [];
  let stderr = '';
  child.stderr.on('data', bytes => { stderr += bytes; });
  lines(child.stdout, record => records.push(record), error => { stderr += error.message; });
  child.stdin.on('error', () => {});
  return { child, records, error: () => stderr,
    send: request => child.stdin.write(JSON.stringify(request) + '\n'),
    async rpc(type, id = crypto.randomUUID()) {
      this.send({ type, id });
      return waitFor(() => records.find(r => r.type === 'response' && r.id === id));
    },
    async ready() {
      return waitFor(() => { if (child.exitCode !== null) throw new Error(stderr || 'Client exited'); return records.find(r => r.type === 'emacs_pi_bridge_state'); });
    },
    async detach(signal) {
      const exited = once(child, 'close');
      if (signal) child.kill(signal); else child.stdin.end();
      await exited; await sleep(50);
    },
  };
}
test('read-only inventory leaves an absent registry absent', async () => {
  const directory = fs.mkdtempSync('/tmp/pi-inventory-');
  try {
    const runtime = path.join(directory, 'missing');
    assert.deepEqual(await inspectRuntimes({ runtime }), []);
    assert.equal(fs.existsSync(runtime), false);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('inventory authenticates without taking lease or exposing content', async () => {
  const f = fixture(), c = client(f.options);
  try {
    await c.ready();
    c.send({ type: 'question' });
    await waitFor(() => c.records.some(value => value.type === 'extension_ui_request'));
    const [row] = await inspectRuntimes({ runtime: f.options.runtime });
    assert.equal(row.status, 'running');
    assert.equal(row.activity, 'unknown');
    assert.equal(row.hasController, true);
    const text = JSON.stringify(row);
    const privateState = JSON.parse(fs.readFileSync(path.join(row.instance, 'state.json')));
    assert.equal(text.includes(privateState.token), false);
    assert.equal(text.includes('Do not auto approve'), false);
    assert.equal('argv' in row, false);
    assert.equal('error' in row, false);
    assert.equal((await c.rpc('get_state')).success, true);
    await c.detach();
    assert.equal((await inspectRuntimes({ runtime: f.options.runtime }))[0].hasController, false);
  } finally { await cleanup(f, [c]); }
});

test('incomplete/malformed registry records are unknown, never absent', async () => {
  const directory = fs.mkdtempSync('/tmp/pi-inventory-');
  fs.chmodSync(directory, 0o700);
  const instance = path.join(directory, 'a'.repeat(32));
  fs.mkdirSync(instance, { mode: 0o700 });
  try {
    assert.equal((await inspectRuntimes({ runtime: directory }))[0].status, 'unknown');
    fs.writeFileSync(path.join(instance, 'state.json'), '{"token":"must-not-escape"', { mode: 0o600 });
    const result = await inspectRuntimes({ runtime: directory });
    assert.equal(result[0].status, 'unknown');
    assert.equal(JSON.stringify(result).includes('must-not-escape'), false);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

async function cleanup(f, clients) {
  for (const c of clients) if (c.child.exitCode === null && c.child.signalCode === null) await c.detach();
  const name = fs.existsSync(f.options.runtime) && fs.readdirSync(f.options.runtime).find(n => /^[a-f0-9]{32}$/.test(n));
  if (!name) { fs.rmSync(f.dir, { recursive: true, force: true }); return; }
  const infoPath = path.join(f.options.runtime, name, 'state.json');
  const info = JSON.parse(fs.readFileSync(infoPath));
  if (info.status === 'running') {
    const end = client(f.options); await end.ready();
    const result = await end.rpc('emacs_pi_finish'); assert.equal(result.success, true);
    await waitFor(() => end.child.exitCode !== null);
  }
  await waitFor(() => !fs.existsSync(path.join(path.dirname(infoPath), 'rpc.sock')));
  fs.rmSync(f.dir, { recursive: true, force: true });
}

for (const signal of [null, 'SIGKILL']) {
  test(`Pi owns work after client ${signal || 'EOF'}, reconnects without another writer`, { timeout: 20000 }, async () => {
    const f = fixture(), clients = [];
    try {
      const a = client(f.options); clients.push(a); await a.ready();
      const before = await a.rpc('get_state');
      a.send({ type: 'work', id: 'one-work' });
      await waitFor(() => a.records.some(r => r.type === 'work_accepted'));
      await a.detach(signal);
      await waitFor(() => fs.existsSync(path.join(f.dir, 'done')));
      const b = client(f.options); clients.push(b); await b.ready();
      const after = await b.rpc('get_state');
      assert.equal(after.data.pid, before.data.pid);
      assert.equal(after.data.sessionId, before.data.sessionId);
      await b.rpc('get_entries');
      await waitFor(() => b.records.some(r => r.type === 'emacs_pi_bridge_state' && r.activeText.length === 1024 * 1024));
      const result = await b.rpc('emacs_pi_finish'); assert.equal(result.success, true);
      await waitFor(() => b.child.exitCode !== null);
    } finally { await cleanup(f, clients); }
  });
}

test('controller lease cannot be stolen; no implicit restart on transport error', { timeout: 15000 }, async () => {
  const f = fixture(), clients = [];
  try {
    const a = client(f.options); clients.push(a); await a.ready();
    const before = await a.rpc('get_state');
    const b = client(f.options); clients.push(b);
    await waitFor(() => b.child.exitCode !== null);
    assert.match(b.error(), /controlling client/);
    assert.equal((await a.rpc('get_state')).data.pid, before.data.pid);
  } finally { await cleanup(f, clients); }
});

test('pending extension question survives detach; inspect does not acquire lease', { timeout: 15000 }, async () => {
  const f = fixture(), clients = [];
  try {
    const a = client(f.options); clients.push(a); await a.ready();
    a.send({ type: 'question', id: 'ask' });
    await waitFor(() => a.records.some(r => r.type === 'extension_ui_request'));
    await a.detach();
    const instance = await ensureInstance(f.options);
    const socket = net.createConnection(instance.socket); await once(socket, 'connect');
    const responses = [];
    lines(socket, r => responses.push(r), error => { throw error; });
    socket.write(JSON.stringify({ op: 'inspect', version: 1, token: instance.token }) + '\n');
    await once(socket, 'close'); assert.equal(responses[0].status, 'running');
    const b = client(f.options); clients.push(b); const state = await b.ready();
    assert.equal(state.questions[0].id, 'question-1');
  } finally { await cleanup(f, clients); }
});

test('real Pi RPC survives detach and finishes orderly without a model call', {
  skip: process.env.PI_BRIDGE_REAL !== '1', timeout: 25000,
}, async () => {
  const f = fixture(), clients = [];
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = path.join(f.dir, 'agent');
  fs.mkdirSync(process.env.PI_CODING_AGENT_DIR);
  fs.writeFileSync(f.options.sessionFile, JSON.stringify({ type: 'session', version: 3,
    id: 'persistent-bridge-real-smoke', cwd: f.dir, timestamp: new Date().toISOString() }) + '\n');
  f.options.argv = [process.env.PI_EXECUTABLE || 'pi', '--mode', 'rpc', '--offline',
    '--no-extensions', '--no-mcp', '--no-skills', '--no-prompt-templates', '--no-tools',
    '--session', f.options.sessionFile, '--session-dir', path.join(f.dir, 'sessions')];
  try {
    const a = client(f.options); clients.push(a); await a.ready();
    const before = await a.rpc('get_state'); assert.equal(before.success, true);
    const firstInstance = await ensureInstance(f.options);
    a.send({ type: 'bash', id: 'detached-bash', command:
      `printf 'started\\n'; sleep 1; printf done > '${path.join(f.dir, 'real.done')}'; printf 'finished\\n'` });
    await waitFor(() => a.records.some(r => r.type === 'bash_execution_update'));
    await a.detach('SIGKILL');
    await waitFor(() => fs.existsSync(path.join(f.dir, 'real.done')));
    const b = client(f.options); clients.push(b); await b.ready();
    const state = await b.rpc('get_state');
    assert.equal(state.data.sessionId, before.data.sessionId);
    assert.equal((await ensureInstance(f.options)).piPid, firstInstance.piPid);
    const history = await b.rpc('get_messages');
    assert.match(JSON.stringify(history.data), /finished/);
    const finished = await b.rpc('emacs_pi_finish'); assert.equal(finished.success, true);
    await waitFor(() => b.child.exitCode !== null);
  } finally {
    await cleanup(f, clients);
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  }
});

test('spawn failure is recorded and does not leave a daemon socket', { timeout: 15000 }, async () => {
  const f = fixture(), clients = [];
  f.options.argv = ['/definitely-missing-pi-bridge-test'];
  try {
    const c = client(f.options); clients.push(c);
    await waitFor(() => c.child.exitCode !== null);
    assert.match(c.error(), /ENOENT|failed|launch/i);
    const name = fs.readdirSync(f.options.runtime).find(n => /^[a-f0-9]{32}$/.test(n));
    const info = JSON.parse(fs.readFileSync(path.join(f.options.runtime, name, 'state.json')));
    assert.equal(info.status, 'failed');
  } finally { await cleanup(f, clients); }
});

test('natural backend exit cleans socket; finished history starts a new generation', { timeout: 15000 }, async () => {
  const f = fixture(), clients = [];
  try {
    const a = client(f.options); clients.push(a); await a.ready();
    const first = await ensureInstance(f.options);
    await a.rpc('exit');
    await waitFor(() => a.child.exitCode !== null);
    await sleep(80);
    assert.equal(JSON.parse(fs.readFileSync(first.info)).status, 'exited');
    const b = client(f.options); clients.push(b); await b.ready();
    const next = await ensureInstance(f.options);
    assert.notEqual(next.piPid, first.piPid);
    assert.notEqual(next.generation, first.generation);
  } finally { await cleanup(f, clients); }
});

test('explicit history open recovers only when both old owner PIDs are absent', { timeout: 15000 }, async () => {
  const f = fixture(), clients = [];
  try {
    const a = client(f.options); clients.push(a); await a.ready();
    const first = await ensureInstance(f.options);
    await a.rpc('emacs_pi_finish');
    await waitFor(() => a.child.exitCode !== null); await sleep(80);
    const stale = JSON.parse(fs.readFileSync(first.info));
    Object.assign(stale, { status: 'running', bridgePid: 2147483647, piPid: process.pid });
    fs.writeFileSync(first.info, JSON.stringify(stale), { mode: 0o600 });
    await assert.rejects(ensureInstance(f.options), /Pi may still run/);
    stale.piPid = 2147483646;
    fs.writeFileSync(first.info, JSON.stringify(stale), { mode: 0o600 });
    const b = client(f.options); clients.push(b); await b.ready();
    assert.notEqual((await ensureInstance(f.options)).generation, first.generation);
  } finally { await cleanup(f, clients); }
});

test('parallel cold ensure and ended restores select a single writer generation', { timeout: 20000 }, async () => {
  const f = fixture(), clients = [];
  try {
    const initial = await Promise.all(Array.from({length: 16}, () => ensureInstance(f.options)));
    assert.equal(new Set(initial.map(x => x.generation)).size, 1);
    assert.equal(new Set(initial.map(x => x.piPid)).size, 1);
    const c = client(f.options); clients.push(c); await c.ready(); await c.rpc('emacs_pi_finish');
    await waitFor(() => c.child.exitCode !== null); await sleep(80);
    const recovered = await Promise.allSettled(Array.from({length: 16}, () => ensureInstance(f.options)));
    const live = recovered.filter(x => x.status === 'fulfilled').map(x => x.value);
    assert.ok(live.length); assert.equal(new Set(live.map(x => x.generation)).size, 1);
    assert.notEqual(live[0].generation, initial[0].generation);
    assert.ok(recovered.filter(x => x.status === 'rejected').every(x => /launch already in progress/.test(x.reason.message)));
  } finally { await cleanup(f, clients); }
});

test('ended and EPERM records never authorize a replacement for a possibly live Pi', { timeout: 15000 }, async () => {
  const f = fixture(), clients = []; let record, original;
  const kill = process.kill;
  try {
    const c = client(f.options); clients.push(c); await c.ready();
    await c.rpc('get_state');
    const info = await ensureInstance(f.options); record = info.info; original = fs.readFileSync(record);
    const state = JSON.parse(original);
    fs.writeFileSync(record, JSON.stringify({...state, status:'finished', bridgePid:2147483647, piPid:process.pid}));
    await assert.rejects(ensureInstance(f.options), /may still run/);
    process.kill = (pid, signal) => { if(pid===2147483647) { const e=new Error('permission denied');e.code='EPERM';throw e; } return kill(pid, signal); };
    fs.writeFileSync(record, JSON.stringify({...state, status:'running', bridgePid:2147483647, piPid:2147483646}));
    assert.equal((await ensureInstance(f.options)).generation, state.generation);
    assert.equal(JSON.parse(fs.readFileSync(record)).bridgePid, 2147483647);
    for (const invalid of [{...state,piPid:undefined}, {...state,bridgePid:-1}, {...state,version:99}]) {
      fs.writeFileSync(record, JSON.stringify(invalid));
      await assert.rejects(ensureInstance(f.options), /Invalid runtime state/);
    }
  } finally { process.kill=kill; if(original) fs.writeFileSync(record, original); await cleanup(f,clients); }
});

test('live owner reattaches with missing history and project; absence cannot launch a replacement', { timeout: 15000 }, async () => {
  const f = fixture(), clients = [];
  const project = path.join(f.dir, 'project'); fs.mkdirSync(project); f.options.cwd=project;
  try {
    const a=client(f.options);clients.push(a);await a.ready(); const before=await ensureInstance(f.options);
    await a.detach();
    const link=path.join(f.dir,'history-link');fs.symlinkSync(f.options.sessionFile,link);
    fs.unlinkSync(f.options.sessionFile); fs.rmdirSync(project);
    await assert.rejects(ensureInstance({...f.options,sessionFile:link}),/Unresolved storage symlink/);
    const b=client(f.options);clients.push(b);await b.ready(); const after=await ensureInstance(f.options);
    assert.equal(after.generation,before.generation);assert.equal(after.piPid,before.piPid);
    assert.equal((await b.rpc('get_state')).data.pid,before.piPid);
    await b.rpc('emacs_pi_finish');await waitFor(()=>b.child.exitCode!==null);await sleep(80);
    await assert.rejects(ensureInstance(f.options), /ENOENT|existing/);
    assert.equal(JSON.parse(fs.readFileSync(before.info)).generation,before.generation);
  } finally { await cleanup(f,clients); }
});

test('unindexed live owner and malformed alias records reject history recovery', { timeout: 15000 }, async () => {
  const f=fixture(),clients=[];let original,record,alias;
  try {
    const c=client(f.options);clients.push(c);await c.ready(); await c.rpc('get_state'); const info=await ensureInstance(f.options);
    record=info.info;original=fs.readFileSync(record);const state=JSON.parse(original);
    fs.writeFileSync(record,JSON.stringify({...state,sessionFile:null}));
    await assert.rejects(ensureInstance(f.options), /Unindexed owner/);
    fs.writeFileSync(record,original);
    alias=path.join(f.options.runtime,'a'.repeat(32));fs.mkdirSync(alias,{mode:0o700});
    fs.writeFileSync(path.join(alias,'state.json'),'{"status":"running"}',{mode:0o600});
    await assert.rejects(ensureInstance(f.options), /Invalid runtime state/);
    fs.writeFileSync(path.join(alias,'state.json'),JSON.stringify(state),{mode:0o600});
    await assert.rejects(ensureInstance(f.options), /Multiple runtime owners/);
    fs.rmSync(alias,{recursive:true});
  } finally {if(alias)fs.rmSync(alias,{recursive:true,force:true});if(original)fs.writeFileSync(record,original);await cleanup(f,clients);}
});

test('JSONL failure is terminal, bounded once, and never executes a later record', () => {
  const stream=new PassThrough(),records=[],errors=[];
  lines(stream,r=>records.push(r),e=>errors.push(e));
  stream.write('not-json\n{"type":"dangerous"}\n');stream.write('{"type":"later"}\n');stream.end('partial');
  assert.equal(errors.length,1);assert.equal(records.length,0);
  const good=new PassThrough(),values=[];lines(good,r=>values.push(r),e=>{throw e;});
  const packet=Buffer.from(JSON.stringify({text:'中文\u2028paragraph\u2029end'})+'\r\n');
  for(const byte of packet)good.write(Buffer.from([byte]));good.end();
  assert.deepEqual(values,[{text:'中文\u2028paragraph\u2029end'}]);
});

test('pending request budget leaves the owned backend running', { timeout: 15000 }, async () => {
  const f=fixture(),clients=[];
  try {
    const c=client(f.options);clients.push(c);await c.ready();const before=await ensureInstance(f.options);
    for(let i=0;i<257;i++)c.send({type:'hold',id:'held-'+i});
    await waitFor(()=>c.child.exitCode!==null);assert.match(c.error(),/Pending command limit/);
    const after=await ensureInstance(f.options);assert.equal(after.piPid,before.piPid);assert.equal(after.generation,before.generation);
  } finally {await cleanup(f,clients);}
});

test('duplicate outstanding ID cannot replay a command after a lost client', { timeout: 15000 }, async () => {
  const f=fixture(),clients=[];
  try {
    const a=client(f.options);clients.push(a);await a.ready();const before=await ensureInstance(f.options);
    a.send({type:'hold',id:'only-once'});await a.rpc('get_state');await a.detach('SIGKILL');
    const b=client(f.options);clients.push(b);await b.ready();b.send({type:'hold',id:'only-once'});
    await waitFor(()=>b.child.exitCode!==null);assert.match(b.error(),/Duplicate or reserved request ID/);
    assert.equal((await ensureInstance(f.options)).generation,before.generation);
  } finally {await cleanup(f,clients);}
});

test('slow controller drops without blocking stdout draining or replacing the owner', { timeout: 20000 }, async () => {
  const f=fixture(),clients=[];let socket;
  try {
    const before=await ensureInstance(f.options);
    socket=net.createConnection(before.socket);socket.on('error',()=>{});let armed=false;
    lines(socket,value=>{if(value.op==='ready'){armed=true;socket.pause();socket.write(JSON.stringify({op:'rpc',request:{type:'flood',id:'flood'}})+'\n');}},()=>{});
    socket.on('connect',()=>socket.write(JSON.stringify({op:'attach',version:1,token:before.token})+'\n'));
    await waitFor(()=>armed);await waitFor(()=>fs.existsSync(path.join(f.dir,'flood.done')));
    let rows;for(let i=0;i<100;i++){rows=await inspectRuntimes({runtime:f.options.runtime});if(rows[0]?.hasController===false)break;await sleep(20);}
    assert.equal(rows[0].hasController,false);socket.destroy();
    const c=client(f.options);clients.push(c);const snapshot=await c.ready();
    assert.equal(snapshot.activeTextTruncated,true);assert.ok(Buffer.byteLength(snapshot.activeText)<=4*1024*1024);
    assert.equal((await ensureInstance(f.options)).piPid,before.piPid);
  } finally {socket?.destroy();await cleanup(f,clients);}
});

test('attach-only pins generation and never revives an ended or missing owner', {timeout:15000}, async () => {
  const f=fixture(),clients=[];
  try {
    const c=client(f.options);clients.push(c);await c.ready();await c.rpc('get_state');
    const state=await ensureInstance(f.options);
    const target={runtime:f.options.runtime,instance:state.directory,generation:state.generation,sessionFile:state.sessionFile,sessionId:state.sessionId};
    assert.equal(attachInstance(target).piPid,state.piPid);
    assert.throws(()=>attachInstance({...target,generation:crypto.randomUUID()}),/changed or unavailable/);
    assert.throws(()=>attachInstance({...target,sessionId:'wrong-id'}),/changed or unavailable/);
    await c.rpc('emacs_pi_finish');await waitFor(()=>c.child.exitCode!==null);await sleep(80);
    assert.throws(()=>attachInstance(target),/changed or unavailable/);
    assert.equal(JSON.parse(fs.readFileSync(state.info)).generation,state.generation);
    const missing=path.join(f.dir,'absent');
    assert.throws(()=>attachInstance({...target,runtime:missing}));assert.equal(fs.existsSync(missing),false);
  } finally {await cleanup(f,clients);}
});

test('large supported input and reconnect snapshot drain without changing owners', {timeout:30000}, async () => {
  const f=fixture(),clients=[];
  try {
    const a=client(f.options);clients.push(a);await a.ready();const before=await ensureInstance(f.options);
    a.send({type:'big_echo',id:'big-input',payload:'p'.repeat(9*1024*1024)});
    const reply=await waitFor(()=>a.records.find(r=>r.id==='big-input'),15000);assert.equal(reply.data.size,9*1024*1024);
    a.send({type:'large_question',bytes:9*1024*1024});
    await waitFor(()=>a.records.some(r=>r.id==='question-big'),15000);await a.detach();
    const b=client(f.options);clients.push(b);const state=await b.ready();
    assert.equal(state.questions[0].text.length,9*1024*1024);assert.equal(state.recoveryIncomplete,false);
    assert.equal((await ensureInstance(f.options)).generation,before.generation);
  } finally {await cleanup(f,clients);}
});

for(const [kind,bytes] of [['large_question',17*1024*1024],['many_questions',0]]) {
 test(`snapshot overflow (${kind}) stays explicit and never auto-replies or stops Pi`, {timeout:30000}, async () => {
  const f=fixture(),clients=[];
  try {
    const a=client(f.options);clients.push(a);await a.ready();const before=await ensureInstance(f.options);
    a.send({type:kind,bytes});await waitFor(()=>a.records.some(r=>r.type==='emacs_pi_bridge_recovery_warning'),15000);
    await a.detach();const b=client(f.options);clients.push(b);const state=await b.ready();
    assert.equal(state.recoveryIncomplete,true);assert.equal(state.questionsIncomplete,true);assert.ok(state.questions.length<=256);
    assert.ok(Buffer.byteLength(JSON.stringify(state.questions))<=16*1024*1024);
    assert.equal((await ensureInstance(f.options)).piPid,before.piPid);assert.equal(fs.existsSync(path.join(f.dir,'replies')),false);
    b.send({type:'extension_ui_response',id:kind==='large_question'?'question-big':'q-256',value:true});
    await waitFor(()=>b.child.exitCode!==null);assert.match(b.error(),/context is unavailable/);
    assert.equal(fs.existsSync(path.join(f.dir,'replies')),false);
    assert.equal((await ensureInstance(f.options)).generation,before.generation);
  } finally {await cleanup(f,clients);}
 });
}

test('queue and questions share one aggregate budget and valid queue updates recover it', {timeout:30000}, async () => {
  const f=fixture(),clients=[];
  try {
    const a=client(f.options);clients.push(a);await a.ready();
    a.send({type:'large_question',bytes:9*1024*1024});await waitFor(()=>a.records.some(r=>r.id==='question-big'),15000);
    a.send({type:'big_queue',bytes:9*1024*1024});await waitFor(()=>a.records.some(r=>r.type==='emacs_pi_bridge_recovery_warning'),15000);
    await a.detach();const b=client(f.options);clients.push(b);const state=await b.ready();
    assert.equal(state.queueIncomplete,true);assert.equal(state.questionsIncomplete,false);assert.equal(state.queue,null);
    assert.equal(state.questions.length,1);assert.equal(state.questions[0].text.length,9*1024*1024);
    b.send({type:'big_queue',bytes:0});await waitFor(()=>b.records.some(r=>r.type==='queue_update'));
    await b.rpc('get_entries');
    const fresh=await waitFor(()=>b.records.find(r=>r.type==='emacs_pi_bridge_state'&&r.recoveryIncomplete===false),15000);
    assert.deepEqual(fresh.queue.followUp,[]);assert.equal(fresh.questions.length,1);
  } finally {await cleanup(f,clients);}
});

test('unsafe runtime permissions rejected before launch', async () => {
  const f = fixture();
  fs.mkdirSync(f.options.runtime, { mode: 0o755 }); fs.chmodSync(f.options.runtime, 0o755);
  await assert.rejects(ensureInstance(f.options), /mode 0700/);
  fs.rmSync(f.dir, { recursive: true, force: true });
});
