// Knip configuration for the Ankole bun-workspaces monorepo.
// Consumed by `bun kit analyze unused` (devkit tools/devkit/src/commands/analyze).
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
      entry: ['src/main.ts', 'test/**/*.ts'],
      project: ['src/**/*.ts', 'test/**/*.ts'],
      // The vendored AI SDK is intentionally excluded from current unused-file
      // gates. Its slimming is tracked separately and should not mask app-owned
      // dead code.
      ignore: ['src/ai-gateway-client/**']
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
  // Generated trees are checked through their source schema/codegen workflows,
  // not app-owned dead-code analysis. var/ holds runtime volumes, not source.
  ignore: [
    '**/*.d.ts',
    '**/generated/**',
    'var/**',
    'internals/skills/**',
    'app/agent_computer/src/ai-gateway-client/**'
  ],
  ignoreBinaries: ['cargo', 'napi']
}

export default config
