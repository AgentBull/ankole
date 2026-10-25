// Knip configuration for the Ankole bun-workspaces monorepo.
// Consumed by `bun kit analyze unused` (devkit tools/devkit/src/commands/analyze).
//
// Production entries include CLI and build scripts invoked outside the import
// graph. Tests do not keep production functions alive. Tolerated-unused files
// lives in UNUSED_ALLOWLIST in tools/devkit/src/commands/analyze/config.ts.

import type { KnipConfig } from 'knip'

const config: KnipConfig = {
  // An export with an internal production caller is live code.
  ignoreExportsUsedInFile: true,
  // Mix-only packages have package.json files for workspace scripts, but no TS
  // graph for Knip to analyze.
  ignoreWorkspaces: ['app/control_plane', 'plugins/lark_adapter'],
  workspaces: {
    '.': {
      entry: [
        'tools/deploy/kubernetes/update-schema.ts!',
        'tools/e2e/support/pod_content_browser.mjs!',
        'internals/webapps/account.tsx!',
        'internals/webapps/pod.tsx!',
        'app/library/agent-plugins/lark/skills/lark-approvals/scripts/profile-setup.ts!'
      ]
    },
    'app/ankole-browser': {
      entry: ['src/cli/main.ts!', 'src/daemon/main.ts!', 'src/runner/bootstrap.ts!'],
      project: ['src/**/*.ts!', '!src/**/*.test.ts!']
    },
    'app/agent_computer': {
      entry: [
        'src/main.ts!',
        'src/worker/function-compute-bootstrap.ts!',
        'src/worker/lambda-hooks.ts!',
        'src/automation-jobs/sdk.ts!',
        'scripts/*.ts',
        'src/cli/**/*-cli.ts!'
      ],
      project: ['src/**/*.ts!', '!src/**/*.test.ts!']
    },
    'app/website': {
      entry: ['astro.config.mjs!', 'scripts/*.mjs!']
    },
    'tools/deploy/cloudflare/agent-workers': {
      entry: ['scripts/deploy.ts!']
    },
    'app/webapps': {
      entry: [
        'entrypoints/*.tsx!',
        'entrypoints/applet-vendor/*.ts!',
        'openapi-ts.config.ts!',
        'vite.config.ts!',
        'playwright.*.config.ts!'
      ],
      project: [
        'auth/**/*.{ts,tsx}!',
        'common/**/*.{ts,tsx}!',
        'console/**/*.{ts,tsx}!',
        'entrypoints/**/*.{ts,tsx}!',
        'setup/**/*.{ts,tsx}!',
        'pod/**/*.{ts,tsx}!',
        '*.ts!'
      ]
    },
    'app/function_runtime': {
      entry: ['main/index.ts!'],
      project: ['main/**/*.ts!']
    },
    'app/kernel': {
      entry: ['scripts/build-node-addon.ts!']
    },
    'libs/uikit': {
      entry: ['src/index.ts!'],
      project: ['src/**/*.{ts,tsx}!'],
      ignore: ['src/stories/**']
    },
    'libs/ankole-editor': {
      entry: [
        'src/index.ts!',
        'src/document/index.ts!',
        'src/editor/index.ts!',
        'scripts/*.ts!',
        'playground/*.{ts,tsx}!'
      ],
      project: ['src/**/*.{ts,tsx}!', 'scripts/*.ts!', 'playground/*.{ts,tsx}!']
    },
    'tools/devkit': {
      entry: ['src/main.ts!', 'src/schematics/**/index.ts!', 'src/changelog-release.ts!', 'src/runtime-image-pair.ts!'],
      project: ['src/**/*.ts!', '!src/**/*.test.ts!']
    }
  },
  // Generated trees are checked through their source schema/codegen workflows,
  // not app-owned dead-code analysis. var/ holds runtime volumes, not source.
  ignore: [
    '**/*.d.ts',
    '**/test/**',
    '**/*.test.ts',
    '**/.astro/**',
    '**/generated/**',
    'var/**',
    'internals/skills/**'
  ],
  ignoreBinaries: ['cargo', 'napi']
}

export default config
