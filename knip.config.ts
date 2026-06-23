// Knip configuration for the Ankole Agent bun-workspaces monorepo.
// Consumed by `bun run kit analyze unused` (devkit tools/devkit/src/commands/analyze).
//
// Entry points declared here are treated as USED, so the unused-files gate only
// flags genuinely unreferenced files. Tolerated-unused residue (with owner/reason)
// lives in UNUSED_ALLOWLIST in tools/devkit/src/commands/analyze/config.ts.

import type { KnipConfig } from 'knip'

const config: KnipConfig = {
  // Rust/napi package: no TS graph to analyze.
  ignoreWorkspaces: ['packages/native-addons'],
  workspaces: {
    app: {
      entry: [
        'src/main.ts',
        'webui/src/entries/*.tsx', // Bun build entrypoints (app/scripts/build-web-assets.ts)
        'drizzle.config.ts', // drizzle-kit
        'src/common/db-migrate.ts', // migrate:local script
        'scripts/build-web-assets.ts'
      ],
      project: ['src/**/*.{ts,tsx}', 'webui/src/**/*.{ts,tsx}'],
      // uikit is a vendored design-system (base-ui/shadcn); unused components are
      // expected library surface, not dead app code.
      ignore: ['webui/src/uikit/**']
    },
    'packages/sdk': {
      entry: ['src/index.ts', 'src/plugins.ts'], // package "." and "./plugins" exports
      project: ['src/**/*.ts']
    },
    'packages/computer': {
      entry: ['client-sdk/index.ts'], // package "." export; src/ is Rust
      project: ['client-sdk/**/*.ts']
    },
    'plugin/lark-adapter': {
      entry: ['src/index.ts'],
      project: ['src/**/*.ts']
    },
    'tools/devkit': {
      entry: ['src/main.ts', 'src/schematics/**/index.ts'],
      project: ['src/**/*.ts']
    }
  },
  // var/ holds dev-worker runtime volumes (browser caches etc.), not source.
  ignore: ['**/*.d.ts', 'var/**', 'internals/skills/**'],
  ignoreBinaries: ['cargo', 'napi']
}

export default config
