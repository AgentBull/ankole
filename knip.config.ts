// Knip configuration for the Ankole bun-workspaces monorepo.
// Consumed by `bun run kit analyze unused` (devkit tools/devkit/src/commands/analyze).
//
// Entry points declared here are treated as USED, so the unused-files gate only
// flags genuinely unreferenced files. Tolerated-unused residue (with owner/reason)
// lives in UNUSED_ALLOWLIST in tools/devkit/src/commands/analyze/config.ts.

import type { KnipConfig } from 'knip'

const config: KnipConfig = {
  // Mix-only packages have package.json files for workspace scripts, but no TS
  // graph for Knip to analyze.
  ignoreWorkspaces: ['app/control_plane', 'libs/feishu_openapi'],
  workspaces: {
    'app/agent_computer': {
      entry: ['src/browser_cli.ts', 'src/main.ts', 'src/turn_child.ts', 'test/**/*.ts'],
      project: ['src/**/*.ts', 'test/**/*.ts'],
      // The vendored AI SDK is intentionally excluded from current unused-file
      // gates. Its slimming is tracked separately and should not mask app-owned
      // dead code.
      ignore: ['src/llm/**']
    },
    'app/kernel': {
      entry: ['test/**/*.ts'],
      project: ['test/**/*.ts']
    },
    'app/webapps': {
      entry: ['entrypoints/*.tsx', 'openapi-ts.config.ts', 'vite.config.ts'],
      project: [
        'auth/**/*.{ts,tsx}',
        'common/**/*.{ts,tsx}',
        'console/**/*.{ts,tsx}',
        'entrypoints/**/*.{ts,tsx}',
        'setup/**/*.{ts,tsx}',
        '*.ts'
      ]
    },
    'libs/uikit': {
      entry: ['src/index.ts'],
      project: ['src/**/*.{ts,tsx}'],
      ignore: ['src/stories/**']
    },
    'tools/devkit': {
      entry: ['src/main.ts', 'src/schematics/**/index.ts'],
      project: ['src/**/*.ts']
    }
  },
  // var/ holds dev-worker runtime volumes (browser caches etc.), not source.
  ignore: ['**/*.d.ts', 'var/**', 'internals/skills/**', 'app/agent_computer/src/llm/**'],
  ignoreBinaries: ['cargo', 'napi']
}

export default config
