// node-pty's prebuilt tarballs lose the executable bit on spawn-helper
// when extracted by npm, which makes pty.spawn fail with "posix_spawnp failed."
// Restore exec perms on every install.
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', 'node_modules', 'node-pty', 'prebuilds');
if (!fs.existsSync(root)) process.exit(0);

for (const platform of fs.readdirSync(root)) {
  const helper = path.join(root, platform, 'spawn-helper');
  if (fs.existsSync(helper)) {
    try {
      fs.chmodSync(helper, 0o755);
    } catch {
      // best-effort
    }
  }
}
