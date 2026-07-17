import { isAbsolute, relative, resolve, sep } from 'node:path'

export function relativePathWithin(rootPath: string, candidatePath: string): string | undefined {
  const root = resolve(rootPath)
  const candidate = resolve(candidatePath)
  const rel = relative(root, candidate)
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return undefined
  return rel
}

export function pathIsWithin(rootPath: string, candidatePath: string): boolean {
  return relativePathWithin(rootPath, candidatePath) !== undefined
}

export function resolvePathWithin(rootPath: string, relativePath: string, errorMessage: string): string {
  const root = resolve(rootPath)
  const candidate = resolve(root, relativePath)
  if (relativePathWithin(root, candidate) === undefined) throw new Error(errorMessage)
  return candidate
}
