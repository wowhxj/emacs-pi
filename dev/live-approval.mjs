// Test-only extension, loaded explicitly in a disposable agent directory.
// It never grants access to arbitrary tools/commands or user paths.
import fs from 'node:fs';
import path from 'node:path';
export default function (pi) {
  const root = process.env.PI_LIVE_ROOT;
  if (!root || !root.startsWith('/tmp/pi-live-') && !root.startsWith('/private/tmp/pi-live-')) throw new Error('Disposable live-test root required');
  const command = `printf 'LIVE\\n' >> '${path.join(root, 'work', 'marker')}'`;
  fs.writeFileSync(path.join(root, 'extension-loaded'), 'loaded', {mode:0o600});
  pi.on('tool_call', async (event, ctx) => {
    if (event.toolName !== 'bash' || event.input.command !== command || fs.existsSync(path.join(root, 'work', 'marker'))) {
      return {block:true, reason:'Only the exact one-shot test marker command is authorized'};
    }
    const ok = await ctx.ui.confirm('LIVE-PROBE-ONLY', command);
    if (!ok) return {block:true, reason:'Test confirmation not granted'};
    fs.appendFileSync(path.join(root, 'tool-approved'), 'approved\n', {mode:0o600});
  });
}
