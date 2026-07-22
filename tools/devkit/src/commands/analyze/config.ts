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

// ---------------------------------------------------------------------------
// unused: Knip
// ---------------------------------------------------------------------------

/** Top-level dirs whose paths are real repo files in Knip's compact output. */
export const UNUSED_REPO_PATH_PREFIX = /^(app|libs|plugins|tools)\//

export const UNUSED_KNIP_ARGS = ['--no-progress', '--reporter', 'compact', '--files', '--no-config-hints'] as const

// ---------------------------------------------------------------------------
// structure: konsistent
// ---------------------------------------------------------------------------

export const STRUCTURE_KONSISTENT_CONFIG_PATH = 'konsistent.json'
export const STRUCTURE_KONSISTENT_VALIDATE_ARGS = [
  'validate',
  '--config-path',
  STRUCTURE_KONSISTENT_CONFIG_PATH
] as const
export const STRUCTURE_KONSISTENT_CHECK_ARGS = [
  'check',
  '--config-path',
  STRUCTURE_KONSISTENT_CONFIG_PATH,
  '--format=json',
  '--max-diagnostics=1000'
] as const

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
    file: 'app/library/agent-plugins/deep-research/workspace-template/tools/list_playbooks.ts',
    owner: 'deep-research Agent Plugin',
    reason: 'Invoked by AGENTS.md for Playbook discovery; the Agent Plugin package is not a Bun workspace.'
  }
]
