// Single source of truth for every Ankole-specific `analyze` constant.
// Policy lives here; algorithms live in ./lib and the per-check modules.
// Tightening or relaxing a guard should be an edit to THIS file only.

import { camelCase } from '@agentbull/active-support'

function pascalCase(value: string): string {
  const camel = camelCase(value)
  return camel ? `${camel.charAt(0).toUpperCase()}${camel.slice(1)}` : ''
}

/** TypeScript production roots where import/boundary checks are meaningful. */
export const TYPESCRIPT_ARCHITECTURE_SCAN_ROOTS = [
  'app/agent_computer/src',
  'app/webapps',
  'libs/uikit/src',
  'libs/ankole-editor/src',
  'libs/applet-sdk/src',
  'app/ankole-browser/src',
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
    category: 'shared-editor-sdk-imports-app',
    appliesTo: /^libs\/(ankole-editor|applet-sdk)\/src\//,
    forbidResolvedPrefixes: ['app/', 'tools/'],
    forbidBareSpecifiers: [
      /^@ankole\/(agent-computer|webapps|control-plane|kernel|browser)(\/|$)/,
      /^@agentbull\/devkit(\/|$)/
    ],
    reason: 'shared editor and Applet SDK modules must not depend on applications or repository tooling'
  },
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
    category: 'uikit-viz-imports-react',
    appliesTo: /^libs\/uikit\/src\/viz\//,
    forbidResolvedPrefixes: ['libs/uikit/src/components/', 'libs/uikit/src/hooks/', 'libs/uikit/src/index.ts'],
    forbidBareSpecifiers: [/^react(?:-dom)?(\/|$)/],
    reason: 'uikit/viz must stay framework-free so both UIKit components and the headless Worker CLI can share it'
  },
  {
    category: 'agent-computer-imports-frontend',
    appliesTo: /^app\/agent_computer\/src\//,
    forbidResolvedPrefixes: [
      'app/webapps/',
      'libs/uikit/src/components/',
      'libs/uikit/src/hooks/',
      'libs/uikit/src/lib/',
      'libs/uikit/src/index.ts'
    ],
    forbidBareSpecifiers: [/^@ankole\/webapps(\/|$)/, /^@ankole\/uikit(?:$|\/(?!viz\/))/],
    reason:
      'agent-computer is a worker runtime and must not import frontend UI packages (only framework-free @ankole/uikit/viz/* is shared)'
  }
]

export const UNUSED_KNIP_ARGS = [
  '--production',
  '--include',
  'files,exports,types,dependencies',
  '--no-progress',
  '--reporter',
  'json',
  '--no-config-hints'
] as const

export interface StructureImportRequirement {
  name: string
  from: string
}

export interface StructureSourceRule {
  kind: 'source'
  name: string
  directory: string
  maxDepth?: number
  subpathPattern: RegExp
  exportFunctions?: (captures: Record<string, string | undefined>) => string[]
  importValues?: (captures: Record<string, string | undefined>) => StructureImportRequirement[]
  declareConstants?: (captures: Record<string, string | undefined>) => string[]
}

export interface StructureDirectoryRule {
  kind: 'directory'
  name: string
  parentDirectory: string
  requiredFiles: (entryName: string) => string[]
}

type StructureRule = StructureSourceRule | StructureDirectoryRule

export const STRUCTURE_RULES: readonly StructureRule[] = [
  {
    kind: 'source',
    name: 'webapp-app-exports',
    directory: 'app/webapps',
    maxDepth: 2,
    subpathPattern: /^(?<appName>auth|console|pod|setup)\/app\.tsx$/,
    exportFunctions: ({ appName }) => [`${pascalCase(appName!)}App`]
  },
  {
    kind: 'source',
    name: 'webapp-entrypoints',
    directory: 'app/webapps/entrypoints',
    subpathPattern: /^(?<appName>[^/]+)\.tsx$/,
    importValues: () => [{ name: 'mountApp', from: '../common/mount' }]
  },
  {
    kind: 'source',
    name: 'webapp-direct-entrypoint-app-imports',
    directory: 'app/webapps/entrypoints',
    subpathPattern: /^(?<appName>auth|console|pod)\.tsx$/,
    importValues: ({ appName }) => [{ name: `${pascalCase(appName!)}App`, from: `../${appName!}/app` }]
  },
  {
    kind: 'source',
    name: 'webapp-setup-entrypoint-lazy-app',
    directory: 'app/webapps/entrypoints',
    subpathPattern: /^setup\.tsx$/,
    declareConstants: () => ['SetupApp']
  },
  {
    kind: 'source',
    name: 'computer-tool-factories',
    directory: 'app/agent_computer/src/tools/computer',
    subpathPattern: /^(?<toolName>[^/]+)-tool\.ts$/,
    exportFunctions: ({ toolName }) => [`create${pascalCase(toolName!)}Tool`]
  },
  {
    kind: 'directory',
    name: 'plugin-root-files',
    parentDirectory: 'plugins',
    requiredFiles: pluginName => [`lib/ankole/plugins/${pluginName}.ex`]
  }
]

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
    file: 'app/library/agent-plugins/deep-research/workspace-template/tools/ach_check.ts',
    owner: 'deep-research Agent Plugin',
    reason: 'Invoked by the ACH Playbook; the Agent Plugin package is not a Bun workspace.'
  },
  {
    file: 'app/library/agent-plugins/deep-research/workspace-template/tools/list_playbooks.ts',
    owner: 'deep-research Agent Plugin',
    reason: 'Invoked by AGENTS.md for Playbook discovery; the Agent Plugin package is not a Bun workspace.'
  },
  {
    file: 'app/library/agent-plugins/office/tools/list_playbooks.ts',
    owner: 'office Agent Plugin',
    reason:
      'Invoked by the docx, xlsx, and pptx Skills for Playbook discovery; the Agent Plugin package is not a Bun workspace.'
  }
]
