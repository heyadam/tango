// Correctness-focused lint: Next.js + React + react-hooks rules (the
// exhaustive-deps rule is load-bearing here — the canvas perf contract
// depends on useCallback stability). No formatting rules by design.
import { defineConfig, globalIgnores } from 'eslint/config';
import nextVitals from 'eslint-config-next/core-web-vitals';
import nextTs from 'eslint-config-next/typescript';

export default defineConfig([
  ...nextVitals,
  ...nextTs,
  {
    rules: {
      // React-Compiler-era hooks rules. They flag patterns this codebase uses
      // deliberately and documents in CLAUDE.md (latest-value refs assigned
      // during render, mount-sync setState effects). Warn, don't fail —
      // revisit when the planned UIMockCanvas hook extraction lands.
      'react-hooks/refs': 'warn',
      'react-hooks/set-state-in-effect': 'warn',
      'react-hooks/static-components': 'warn',
      'react-hooks/preserve-manual-memoization': 'warn',
      // Underscore prefix = intentional discard (destructure-and-drop, unused
      // callback params) — the convention this codebase already uses.
      '@typescript-eslint/no-unused-vars': [
        'warn',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          destructuredArrayIgnorePattern: '^_',
        },
      ],
    },
  },
  {
    // Plain-Node CJS utility scripts (postinstall etc.) — require() is right.
    files: ['scripts/**/*.js'],
    rules: {
      '@typescript-eslint/no-require-imports': 'off',
    },
  },
  globalIgnores([
    '.next/**',
    'out/**',
    'build/**',
    'next-env.d.ts',
    // Generated Swift goldens and the committed preview-host app.
    'src/lib/__snapshots__/**',
    'preview-host/**',
    // Untracked local scratch.
    '.bench/**',
    '.tango/**',
  ]),
]);
