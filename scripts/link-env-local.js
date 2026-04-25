// Worktrees don't inherit the main repo's `.env.local` (it's untracked).
// Next.js loads env files from cwd, so without this every `git worktree add`
// would silently lose API keys. Symlink from the main repo's working tree
// when running inside a worktree.

const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const here = path.resolve(__dirname, '..');
const target = path.join(here, '.env.local');

if (fs.existsSync(target)) process.exit(0);

let commonDir;
try {
  commonDir = execSync('git rev-parse --git-common-dir', {
    cwd: here,
    encoding: 'utf8',
  }).trim();
} catch {
  process.exit(0);
}

const absCommon = path.isAbsolute(commonDir)
  ? commonDir
  : path.join(here, commonDir);
const mainRepo = path.dirname(absCommon);

if (path.resolve(mainRepo) === path.resolve(here)) process.exit(0);

const source = path.join(mainRepo, '.env.local');
if (!fs.existsSync(source)) process.exit(0);

try {
  fs.symlinkSync(source, target);
  console.log(`linked .env.local -> ${source}`);
} catch (e) {
  console.warn(`could not link .env.local: ${e.message}`);
}
