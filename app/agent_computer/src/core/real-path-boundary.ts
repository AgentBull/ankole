import { existsSync, realpathSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { pathIsWithin } from './path-boundary'

export function canonicalExistingRoots(roots: string[]): string[] {
  return roots.filter(existsSync).map(root => realpathSync(root))
}

export function workspacePhysicalRoots(workspaceRoot: string): string[] {
  const root = resolve(workspaceRoot)
  return canonicalExistingRoots([root, resolve(root, 'user-files')])
}

export function assertExistingPathWithin(roots: string[], path: string, errorMessage: string): string {
  const realPath = realpathSync(path)
  if (!roots.some(root => pathIsWithin(root, realPath))) throw new Error(errorMessage)
  return resolve(path)
}

export function assertCreatablePathWithin(roots: string[], path: string, errorMessage: string): string {
  const target = resolve(path)
  if (existsSync(target)) {
    assertExistingPathWithin(roots, target, errorMessage)
    return target
  }

  let ancestor = dirname(target)
  while (!existsSync(ancestor)) {
    const parent = dirname(ancestor)
    if (parent === ancestor) throw new Error(errorMessage)
    ancestor = parent
  }
  assertExistingPathWithin(roots, ancestor, errorMessage)
  return target
}
