// Single source of truth for every Ankole-specific `analyze` constant.
// Policy lives here; algorithms live in ./lib and the per-check modules.
// Tightening or relaxing a guard should be an edit to THIS file only.

// ---------------------------------------------------------------------------
// Scan roots & source extensions
// ---------------------------------------------------------------------------

/** TypeScript production roots where import/boundary checks are meaningful. */
export const TYPESCRIPT_ARCHITECTURE_SCAN_ROOTS = [
  'app/agent_computer/src',
  'app/webapps',
  'libs/uikit/src',
  'tools/devkit/src'
] as const

/** Source roots scanned for import cycles (repo-root-relative, POSIX). */
export const CYCLE_SCAN_ROOTS = TYPESCRIPT_ARCHITECTURE_SCAN_ROOTS

/** Roots where the boundary/smell rules apply. */
export const SMELL_SCAN_ROOTS = TYPESCRIPT_ARCHITECTURE_SCAN_ROOTS

export const CYCLE_SOURCE_EXTENSIONS = ['.ts', '.tsx', '.mts', '.cts', '.js', '.mjs', '.cjs'] as const

export const SMELL_SOURCE_EXTENSIONS = ['.ts', '.tsx'] as const

/**
 * Per-package tsconfigs whose `compilerOptions.paths` are read to resolve `@/*`
 * aliases in the cycle graph. Only packages that actually define path aliases
 * need listing.
 */
export const ALIAS_TSCONFIGS = [
  { packageRoot: 'app/agent_computer', tsconfig: 'app/agent_computer/tsconfig.json' }
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
  {
    category: 'uikit-imports-app',
    appliesTo: /^libs\/uikit\/src\//,
    forbidResolvedPrefixes: ['app/'],
    forbidBareSpecifiers: [/^@ankole\/(?:agent-computer|webapps|control-plane|kernel)(\/|$)/],
    reason: 'uikit must remain app-agnostic and must not import application internals'
  },
  {
    category: 'webapps-imports-agent-computer',
    appliesTo: /^app\/webapps\//,
    forbidResolvedPrefixes: ['app/agent_computer/'],
    forbidBareSpecifiers: [/^@ankole\/agent-computer(\/|$)/],
    reason: 'webapps must communicate through control-plane APIs, not import worker internals'
  },
  {
    category: 'agent-computer-imports-frontend',
    appliesTo: /^app\/agent_computer\/src\//,
    forbidResolvedPrefixes: ['app/webapps/', 'libs/uikit/'],
    forbidBareSpecifiers: [/^@ankole\/(?:webapps|uikit)(\/|$)/],
    reason: 'agent-computer is a worker runtime and must not import frontend packages'
  }
]

// ④ public-ish barrels must only re-export from an allowed module list.
//    Every entry must be on the current runtime path; widening this list is a
//    deliberate public-surface decision.

export interface BarrelAllowlist {
  allowed: string[]
  note: string
}

export const BARREL_ALLOWLIST: Record<string, BarrelAllowlist> = {}

export const BARREL_EXPORT_CATEGORY = 'barrel-export-out-of-allowlist'

// ---------------------------------------------------------------------------
// unused: Knip
// ---------------------------------------------------------------------------

/** Top-level dirs whose paths are real repo files in Knip's compact output. */
export const UNUSED_REPO_PATH_PREFIX = /^(app|libs|plugins|tools)\//

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
export const UNUSED_ALLOWLIST: UnusedAllowEntry[] = [
  {
    file: 'app/webapps/console/api/generated/index.ts',
    owner: 'webapps-console-api',
    reason: 'Generated OpenAPI barrel; current consumers import generated query/types modules directly.'
  }
]

// ---------------------------------------------------------------------------
// duplicates: jscpd v5
// ---------------------------------------------------------------------------

export const DUP_FORMATS = 'typescript,tsx,javascript,jsx,elixir,rust'
export const DUP_THRESHOLDS = { minLines: 50, minTokens: 300 } as const

/** Glob patterns excluded from duplicate scanning (jscpd --ignore). */
export const DUP_IGNORE_PATTERNS = [
  '**/node_modules/**',
  '**/dist/**',
  '**/build/**',
  '**/target/**',
  '**/.turbo/**',
  '**/coverage/**',
  '**/.artifacts/**',
  '**/_build/**',
  '**/deps/**',
  '**/*.test.ts',
  '**/*.test.tsx',
  '**/*.d.ts',
  '**/migrations/**',
  'app/control_plane/lib/ankole/ai_gateway/**',
  'app/control_plane/lib/ankole_web/ai_gateway_*.ex',
  'app/control_plane/lib/ankole_web/controllers/ai_gateway_*.ex',
  'libs/uikit/src/stories/**'
] as const

export interface DupScan {
  name: string
  paths: string[]
}

/** jscpd scan groups. One cross-module production scan is enough for Ankole. */
export const DUP_SCANS: DupScan[] = [
  {
    name: 'cross-module',
    paths: [
      'app/agent_computer/src',
      'app/control_plane/lib',
      'app/kernel/build.rs',
      'app/kernel/index.js',
      'app/kernel/lib',
      'app/kernel/main.js',
      'app/kernel/src',
      'app/webapps',
      'libs/feishu_openapi/lib',
      'libs/uikit/src',
      'plugins',
      'tools/devkit/src'
    ]
  }
]

/** Tracked source extensions used by the --coverage-only assertion. */
export const DUP_SOURCE_EXTENSIONS = new Set(['.ts', '.tsx', '.js', '.mjs', '.cjs', '.ex', '.rs'])

/**
 * Top-level source areas deliberately NOT duplicate-scanned (so --coverage-only
 * does not flag them). Everything tracked must be either under a DUP_SCANS path
 * or under one of these prefixes.
 */
export const DUP_INTENTIONALLY_UNSCANNED = [
  'app/agent_computer/test/',
  'app/control_plane/config/',
  'app/control_plane/e2e/',
  'app/control_plane/lib/ankole/ai_gateway.ex',
  'app/control_plane/lib/ankole/ai_gateway/',
  'app/control_plane/lib/ankole_web/ai_gateway_tokens.ex',
  'app/control_plane/lib/ankole_web/ai_gateway_responses_socket.ex',
  'app/control_plane/lib/ankole_web/controllers/ai_gateway_controller.ex',
  'app/control_plane/lib/ankole_web/controllers/ai_gateway_provider_controller.ex',
  'app/control_plane/lib/ankole_web/controllers/ai_gateway_web_socket_controller.ex',
  'app/control_plane/test/',
  'app/kernel/test/',
  'libs/feishu_openapi/test/',
  'libs/uikit/src/stories/',
  'internals/',
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
  'agent-computer-core': {
    entrypointRoot: 'app/agent_computer/src/core',
    importPrefix: '@/core',
    description: 'Agent Computer core public surface'
  },
  'agent-computer-tools': {
    entrypointRoot: 'app/agent_computer/src/tools/computer',
    importPrefix: '@/tools/computer',
    description: 'Agent Computer computer-tool surface'
  }
} as const

export const DEFAULT_TOPOLOGY_SCOPE = 'agent-computer-core'

/**
 * Scopes where `unused-public-surface` is a CI gate. Keep this empty while
 * topology is report-only; add scopes here only when a public surface is stable
 * enough for unused exports to fail CI.
 */
export const TOPOLOGY_GATED_SCOPES = ['agent-computer-core', 'agent-computer-tools'] as const

export interface TopologyUnusedAllowEntry {
  scope: string
  exportName: string
  owner: string
  reason: string
}

export const TOPOLOGY_UNUSED_ALLOWLIST: TopologyUnusedAllowEntry[] = []
