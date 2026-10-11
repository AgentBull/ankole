import { existsSync, lstatSync, realpathSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { pathIsWithin } from './path-boundary'

export function canonicalExistingRoots(roots: string[]): string[] {
  return roots.filter(existsSync).map(root => realpathSync(root))
}

/** Resolves links before the Home check, including the parent of a new file. */
export function canonicalPath(path: string): string {
  let ancestor = resolve(path)
  const missing: string[] = []
  for (;;) {
    try {
      lstatSync(ancestor)
      break
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      missing.unshift(basename(ancestor))
      ancestor = dirname(ancestor)
    }
  }
  // A dangling link is an error. Do not treat it as a missing directory.
  return join(realpathSync(ancestor), ...missing)
}

export function assertExistingPathWithin(roots: string[], path: string, errorMessage: string): string {
  const realPath = realpathSync(path)
  if (!roots.some(root => pathIsWithin(root, realPath))) throw new Error(errorMessage)
  return realPath
}

export function assertCreatablePathWithin(roots: string[], path: string, errorMessage: string): string {
  const target = canonicalPath(path)
  if (!roots.some(root => pathIsWithin(root, target))) throw new Error(errorMessage)
  return target
}
