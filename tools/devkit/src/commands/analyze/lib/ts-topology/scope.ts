// Topology scope construction. Ported from openclaw with bullx retargeting:
// the openclaw plugin-sdk scope (and its bundled-plugin-paths / plugin-sdk-entries
// imports) is dropped; classifiers map bullx top-level dirs (app/, packages/,
// plugin/, tools/, app/webui/). "extension" maps to bullx "plugin".

import fs from 'node:fs'
import path from 'node:path'
import type { ConsumerScope, PublicEntrypoint, TopologyScope, UsageBucket } from './types'

function isTestFile(relPath: string): boolean {
  return (
    relPath.startsWith('test/') ||
    relPath.includes('/__tests__/') ||
    relPath.includes('.test.') ||
    relPath.includes('.spec.') ||
    relPath.includes('.e2e.') ||
    relPath.includes('.suite.') ||
    relPath.includes('test-harness') ||
    relPath.includes('test-support') ||
    relPath.includes('test-helper') ||
    relPath.includes('test-utils')
  )
}

function classifyScope(relPath: string): ConsumerScope {
  if (relPath.startsWith('app/webui/')) {
    return 'webui'
  }
  if (relPath.startsWith('app/')) {
    return 'app'
  }
  if (relPath.startsWith('packages/')) {
    return 'package'
  }
  if (relPath.startsWith('plugin/')) {
    return 'plugin'
  }
  if (relPath.startsWith('tools/')) {
    return 'tool'
  }
  if (relPath.startsWith('test/')) {
    return 'test'
  }
  return 'other'
}

function classifyUsageBucketForRoots(internalRoots: string[], relPath: string): UsageBucket {
  if (internalRoots.some(root => relPath === root || relPath.startsWith(`${root}/`))) {
    return 'internal'
  }
  return isTestFile(relPath) ? 'test' : 'production'
}

function extractOwner(relPath: string): string | null {
  const scope = classifyScope(relPath)
  const parts = relPath.split('/')
  switch (scope) {
    case 'webui':
      return 'webui'
    case 'app':
      // app/src/<subsystem>/... -> the subsystem owns it.
      return parts[1] === 'src' ? (parts[2] ?? 'app') : (parts[1] ?? 'app')
    case 'package':
      return parts[1] ? `package:${parts[1]}` : 'package'
    case 'plugin':
      return parts[1] ? `plugin:${parts[1]}` : 'plugin'
    case 'tool':
      return parts[1] ? `tool:${parts[1]}` : 'tool'
    case 'other':
      return parts[0] || 'other'
    case 'test':
      return null
  }
  throw new Error('Unsupported topology scope')
}

/** Owner-as-plugin (openclaw "extension" id) when the consumer lives in plugin/. */
function extractExtensionId(relPath: string): string | null {
  if (!relPath.startsWith('plugin/')) {
    return null
  }
  const parts = relPath.split('/')
  return parts[1] ?? null
}

function extractPackageOwner(relPath: string): string | null {
  const owner = extractOwner(relPath)
  return owner?.startsWith('plugin:') ? null : owner
}

function buildScopeFromEntrypoints(id: string, description: string, entrypoints: PublicEntrypoint[]): TopologyScope {
  const internalRoots = [...new Set(entrypoints.map(entrypoint => path.posix.dirname(entrypoint.sourcePath)))]
  const publicSpecifiers = new Set(entrypoints.map(entrypoint => entrypoint.importSpecifier))
  return {
    id,
    description,
    entrypoints,
    importFilter(specifier: string) {
      return publicSpecifiers.has(specifier)
    },
    classifyUsageBucket(relPath: string) {
      return classifyUsageBucketForRoots(internalRoots, relPath)
    },
    classifyScope,
    ownerForPath(relPath: string) {
      return extractOwner(relPath)
    },
    extensionForPath(relPath: string) {
      return extractExtensionId(relPath)
    },
    packageOwnerForPath(relPath: string) {
      return extractPackageOwner(relPath)
    }
  }
}

export function createFilesystemPublicSurfaceScope(
  repoRoot: string,
  options: {
    id: string
    description?: string
    entrypointRoot: string
    importPrefix: string
  }
): TopologyScope {
  const absoluteRoot = path.join(repoRoot, options.entrypointRoot)
  const entries = fs
    .readdirSync(absoluteRoot, { withFileTypes: true })
    .filter(entry => entry.isFile() && entry.name.endsWith('.ts') && !entry.name.endsWith('.d.ts'))
    .map(entry => entry.name)
    .toSorted()
  const publicEntrypoints = entries.map(fileName => {
    const entrypoint = fileName.replace(/\.ts$/, '')
    return {
      entrypoint,
      sourcePath: path.posix.join(options.entrypointRoot, fileName),
      importSpecifier: entrypoint === 'index' ? options.importPrefix : `${options.importPrefix}/${entrypoint}`
    }
  })
  return buildScopeFromEntrypoints(
    options.id,
    options.description ?? `Public surface rooted at ${options.entrypointRoot}`,
    publicEntrypoints
  )
}
