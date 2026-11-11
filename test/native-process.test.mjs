// Opt-in, no-model integration: actual Emacs processes -> bundled proxy -> real Pi.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const script = fileURLToPath(new URL('./native-process-child.el', import.meta.url));
async function waitFor(predicate, timeout = 18000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = predicate(); if (value) return value; await new Promise(r => setTimeout(r, 30)); }
  throw new Error('Real Emacs/Pi smoke deadline exceeded');
}
function metadata(root) {
  const runtime = path.join(root, 'run');
  const dir = fs.readdirSync(runtime).find(name => /^[a-f0-9]{32}$/.test(name));
  return JSON.parse(fs.readFileSync(path.join(runtime, dir, 'state.json')));
}
function emacs(root, mode) {
  const markdown = process.env.EMACS_PI_TEST_MARKDOWN;
  assert.ok(markdown && fs.existsSync(markdown), 'Set EMACS_PI_TEST_MARKDOWN to the installed markdown-mode directory');
  const child = spawn(process.env.EMACS || 'emacs', ['--batch', '-Q', '-L', repo, '-L', markdown,
    '--eval', '(setq load-prefer-newer t)', '-l', script], {
    cwd: root, env: { ...process.env, PI_CODING_AGENT_DIR: path.join(root, 'agent'),
      EMACS_PI_SMOKE_ROOT: root, EMACS_PI_SMOKE_MODE: mode },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = '';
  child.stdout.on('data', b => { log += b; }); child.stderr.on('data', b => { log += b; });
  return { child, log: () => log };
}
for (const mode of ['normal', 'crash']) {
  test(`native Emacs ${mode} exit preserves real Pi and new Emacs finishes it`, {
    skip: process.env.PI_BRIDGE_REAL !== '1', timeout: 40000,
  }, async () => {
    const root = fs.mkdtempSync('/tmp/pi-native-'); fs.chmodSync(root, 0o700);
    fs.mkdirSync(path.join(root, 'agent'), { mode: 0o700 });
    fs.writeFileSync(path.join(root, 'history.jsonl'), JSON.stringify({ type: 'session', version: 3,
      id: 'native-process-smoke', cwd: root, timestamp: new Date().toISOString() }) + '\n');
    let first, second;
    try {
      first = emacs(root, mode);
      await waitFor(() => {
        if (first.child.exitCode !== null && !fs.existsSync(path.join(root, 'armed'))) throw new Error(first.log());
        return fs.existsSync(path.join(root, 'armed'));
      });
      const before = metadata(root);
      assert.equal(before.status, 'running');
      const closed = first.child.exitCode !== null ? Promise.resolve([first.child.exitCode]) : once(first.child, 'close');
      if (mode === 'crash') first.child.kill('SIGKILL');
      const [code, signal] = await closed;
      if (mode === 'normal') assert.equal(code, 0, first.log()); else assert.equal(signal, 'SIGKILL');
      await waitFor(() => fs.existsSync(path.join(root, 'done')));
      process.kill(before.piPid, 0);
      assert.equal(metadata(root).piPid, before.piPid);
      second = emacs(root, 'resume');
      const [resumedCode] = await once(second.child, 'close');
      assert.equal(resumedCode, 0, second.log());
      assert.ok(fs.existsSync(path.join(root, 'resumed')));
      const after = metadata(root);
      assert.equal(after.piPid, before.piPid);
      assert.equal(after.status, 'finished');
      assert.ok(fs.existsSync(path.join(root, 'history.jsonl')));
    } finally {
      for (const c of [first, second]) if (c && c.child.exitCode === null && c.child.signalCode === null) c.child.kill('SIGKILL');
      // Test-owned generation only. Try an ordinary client finish before considering fixture cleanup failed.
      let state;
      try { state = metadata(root); } catch {}
      if (state?.status === 'running') {
        const cleanup = emacs(root, 'resume');
        await once(cleanup.child, 'close');
        state = metadata(root);
      }
      if (state && !['finished', 'failed', 'exited'].includes(state.status)) {
        throw new Error(`Test runtime left ${state.status}; retained fixture at ${root}`);
      }
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
