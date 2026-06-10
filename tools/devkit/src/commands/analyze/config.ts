// Single source of truth for every BullX-specific `analyze` constant.
// Policy lives here; algorithms live in ./lib and the per-check modules.
// Tightening or relaxing a guard should be an edit to THIS file only.

// ---------------------------------------------------------------------------
// Scan roots & source extensions
// ---------------------------------------------------------------------------

/** Source roots scanned for import cycles (repo-root-relative, POSIX). */
export const CYCLE_SCAN_ROOTS = [
  'app/src',
  'app/webui/src',
  'packages/sdk/src',
  'plugin/lark-adapter/src',
  'tools/devkit/src'
] as const
// NOTE: packages/native-addons is intentionally absent (Rust/napi; only a
// generated index.d.ts, which is skipped anyway).

/** Roots where the boundary/smell rules apply. */
export const SMELL_SCAN_ROOTS = ['app/src', 'packages/sdk/src', 'plugin/lark-adapter/src'] as const

export const CYCLE_SOURCE_EXTENSIONS = ['.ts', '.tsx', '.mts', '.cts', '.js', '.mjs', '.cjs'] as const

export const SMELL_SOURCE_EXTENSIONS = ['.ts', '.tsx'] as const

/**
 * Per-package tsconfigs whose `compilerOptions.paths` are read to resolve `@/*`
 * / `@locales/*` aliases in the cycle graph. Only packages that actually define
 * path aliases need listing (lark-adapter & devkit define none).
 */
export const ALIAS_TSCONFIGS = [
  { packageRoot: 'app', tsconfig: 'app/tsconfig.json' },
  { packageRoot: 'packages/sdk', tsconfig: 'packages/sdk/tsconfig.json' }
] as const

// ---------------------------------------------------------------------------
// smells: boundary rules
// ---------------------------------------------------------------------------

export interface BoundaryRule {
  /** Stable id used in findings + JSON output. */
  category: string
  /** Importer repo path must match for the rule to apply. */
  appliesTo: RegExp
  /** Importer repo paths exempt from the rule (e.g. discovery/runtime points). */
  exemptImporters?: RegExp[]
  /** A relative import is forbidden if its resolved repo path starts with one of these. */
  forbidResolvedPrefixes: string[]
  /** A bare/aliased import is forbidden if its raw specifier matches one of these. */
  forbidBareSpecifiers: RegExp[]
  reason: string
}

export const BOUNDARY_RULES: BoundaryRule[] = [
  // ① SDK must not re-export app/plugin internal implementation.
  {
    category: 'sdk-internal-reexport',
    appliesTo: /^packages\/sdk\/src\//,
    forbidResolvedPrefixes: ['app/', 'plugin/'],
    forbidBareSpecifiers: [/^@agentbull\/bullx-agent(\/|$)/, /^@agentbull\/plugin-/],
    reason: 'sdk public surface must not re-export app/plugin internal implementation'
  },
  // ② plugin/** must not import app internals.
  {
    category: 'plugin-imports-app',
    appliesTo: /^plugin\/[^/]+\/src\//,
    forbidResolvedPrefixes: ['app/'],
    forbidBareSpecifiers: [/^@agentbull\/bullx-agent(\/|$)/, /^@\//],
    reason: 'plugin must not import app internals; depend on @agentbull/bullx-sdk only'
  },
  // ③ app core must not reverse-import plugin implementation (discovery exempt).
  {
    category: 'app-imports-plugin-impl',
    appliesTo: /^app\/src\//,
    exemptImporters: [/^app\/src\/plugins\//],
    forbidResolvedPrefixes: ['plugin/'],
    forbidBareSpecifiers: [/^@agentbull\/plugin-/],
    reason: 'app core must not import plugin implementation (discovery is filesystem/dynamic)'
  }
]

// ④ public-ish barrels must only re-export from an allowed module list.
//    Every entry must be on the current runtime path; widening this list is a
//    deliberate public-surface decision.

export interface BarrelAllowlist {
  allowed: string[]
  note: string
}

export const BARREL_ALLOWLIST: Record<string, BarrelAllowlist> = {
  'app/src/external-gateway/core/index.ts': {
    allowed: ['./capabilities', './events', './projection', './visible-output-stream', './errors'],
    note: 'External Gateway stable runtime surface. Adding a module here is a deliberate public-surface widening.'
  },
  'app/src/ai-agent/core/index.ts': {
    allowed: [
      './agent',
      './agent-loop',
      './harness/compaction/compaction',
      './harness/messages',
      './harness/session/session',
      './harness/skills',
      './harness/types',
      './types',
      './bullx'
    ],
    note: 'AIAgent core surface. Every entry is consumed by the current runtime.'
  }
}

export const BARREL_EXPORT_CATEGORY = 'barrel-export-out-of-allowlist'

// ---------------------------------------------------------------------------
// unused: Knip
// ---------------------------------------------------------------------------

/** Top-level dirs whose paths are real repo files in Knip's compact output. */
export const UNUSED_REPO_PATH_PREFIX = /^(app|packages|plugin|tools)\//

export const UNUSED_KNIP_ARGS = ['--no-progress', '--reporter', 'compact', '--files', '--no-config-hints'] as const

export interface UnusedAllowEntry {
  file: string
  owner: string
  reason: string
}

/**
 * Files Knip reports as unused that are intentional. Every entry carries
 * owner/reason. Build entrypoints (webui entries, drizzle config,
 * db-migrate, package exports) are declared as `entry` in knip.config.ts so
 * Knip treats them as used — they do NOT belong here (that would be stale).
 */
export const UNUSED_ALLOWLIST: UnusedAllowEntry[] = []

// ---------------------------------------------------------------------------
// duplicates: jscpd v5
// ---------------------------------------------------------------------------

export const DUP_FORMATS = 'typescript,tsx,javascript,jsx'
export const DUP_THRESHOLDS = { minLines: 50, minTokens: 300 } as const

/** Glob patterns excluded from duplicate scanning (jscpd --ignore-pattern). */
export const DUP_IGNORE_PATTERNS = [
  '**/node_modules/**',
  '**/dist/**',
  '**/build/**',
  '**/target/**',
  '**/.turbo/**',
  '**/coverage/**',
  '**/.artifacts/**',
  '**/*.test.ts',
  '**/*.test.tsx',
  '**/migrations/**',
  'app/webui/src/uikit/**',
  'packages/native-addons/**',
  // Contract type definitions: their shape repetition is intentional, not a
  // clone to merge.
  'packages/sdk/src/plugins.ts'
] as const

export interface DupScan {
  name: string
  paths: string[]
}

/** jscpd scan groups. One cross-module production scan is enough for bullx. */
export const DUP_SCANS: DupScan[] = [{ name: 'cross-module', paths: ['app/src', 'plugin', 'packages'] }]

/** Tracked source extensions used by the --coverage-only assertion. */
export const DUP_SOURCE_EXTENSIONS = new Set(['.ts', '.tsx', '.js', '.mjs', '.cjs'])

/**
 * Top-level source areas deliberately NOT duplicate-scanned (so --coverage-only
 * does not flag them). Everything tracked must be either under a DUP_SCANS path
 * or under one of these prefixes.
 */
export const DUP_INTENTIONALLY_UNSCANNED = [
  'app/webui/',
  'app/scripts/',
  'app/drizzle.config.ts',
  'tools/',
  'knip.config.ts'
] as const

// ---------------------------------------------------------------------------
// topology: ts-topology named scopes
// ---------------------------------------------------------------------------

export interface TopologyScopeConfig {
  entrypointRoot: string
  importPrefix: string
  description: string
}

export const TOPOLOGY_SCOPES: Record<string, TopologyScopeConfig> = {
  // Real consumers of the SDK plugin contract.
  'sdk-plugins': {
    entrypointRoot: 'packages/sdk/src',
    importPrefix: '@agentbull/bullx-sdk',
    description: 'BullX SDK public plugin surface'
  },
  // External Gateway core public-surface usage.
  'eg-core': {
    entrypointRoot: 'app/src/external-gateway/core',
    importPrefix: '@/external-gateway/core',
    description: 'External Gateway core public surface'
  },
  // AIAgent core surface usage.
  'ai-agent-core': {
    entrypointRoot: 'app/src/ai-agent/core',
    importPrefix: '@/ai-agent/core',
    description: 'AIAgent core surface'
  }
} as const

export const DEFAULT_TOPOLOGY_SCOPE = 'sdk-plugins'

/**
 * Scopes where `unused-public-surface` is a CI gate: an internal module surface
 * must not export what nothing consumes. `sdk-plugins` stays report-only — a
 * public contract may legitimately export ahead of external consumers.
 */
export const TOPOLOGY_GATED_SCOPES = ['eg-core', 'ai-agent-core'] as const

export interface TopologyUnusedAllowEntry {
  scope: string
  exportName: string
  owner: string
  reason: string
}

export const TOPOLOGY_UNUSED_ALLOWLIST: TopologyUnusedAllowEntry[] = []
