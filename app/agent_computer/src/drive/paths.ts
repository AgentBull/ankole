import { lstat, readlink, realpath } from 'node:fs/promises'
import { dirname, isAbsolute, join, resolve, sep } from 'node:path'
import { pathIsWithin } from '../core/path-boundary'
import type { DriveView } from './mounts'

export function driveDeadline<T>(operation: Promise<T>, signal = AbortSignal.timeout(15_000)): Promise<T> {
  signal = AbortSignal.any([signal, AbortSignal.timeout(15_000)])
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason)
    if (signal.aborted) {
      reject(signal.reason)
      return
    }
    signal.addEventListener('abort', abort, { once: true })
    operation.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort))
  })
}

/** Resolves each symlink in the execution's namespace, including absolute
 * /workspace -> /drive links which the root supervisor cannot follow directly. */
export async function resolveScopedDrivePath(
  view: DriveView | undefined,
  input: string,
  signal = AbortSignal.timeout(15_000)
): Promise<string> {
  const map = (path: string) => {
    if (!pathIsWithin('/drive', path) && !pathIsWithin('/drive-recovery', path)) return path
    if (!view) throw new Error('This execution has no mounted Drive')
    if (pathIsWithin('/drive-recovery', path)) return join(view.recovery, path.slice('/drive-recovery'.length))
    if (pathIsWithin('/drive/ChatDrive', path)) {
      if (!view.chat) throw new Error('This execution has no ChatDrive')
      return join(view.chat.path, path.slice('/drive/ChatDrive'.length))
    }
    if (['Skills', 'AGENTS.md', 'DESIGN.md'].some(name => pathIsWithin(`/drive/${name}`, path))) {
      return join(view.library.path, path.slice('/drive'.length))
    }
    return join(view.scope.path, path.slice('/drive'.length))
  }
  const operation = async () => {
    let remaining = map(resolve(input)).split(sep).filter(Boolean)
    let current: string = sep
    let links = 0
    while (remaining.length) {
      current = join(current, remaining.shift()!)
      let info
      try {
        info = await lstat(current)
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return join(current, ...remaining)
        throw error
      }
      if (info.isSymbolicLink()) {
        if (++links > 40) throw new Error('Too many symbolic links')
        const target = await readlink(current)
        const expanded = map(isAbsolute(target) ? target : resolve(dirname(current), target))
        remaining = [...expanded.split(sep).filter(Boolean), ...remaining]
        current = sep
      }
    }
    return current
  }
  return driveDeadline(operation(), signal)
}

export async function scopedPath(
  view: DriveView | undefined,
  home: string,
  input: string,
  signal = AbortSignal.timeout(15_000)
): Promise<string> {
  const target = await resolveScopedDrivePath(view, input, signal)
  const roots = [
    await driveDeadline(realpath(home), signal),
    ...(view ? [view.scope.path, view.library.path, view.recovery, ...(view.chat ? [view.chat.path] : [])] : [])
  ]
  if (!roots.some(root => pathIsWithin(root, target))) {
    throw new Error(`Path is outside the agent home and this execution's Drive: ${input}`)
  }
  return target
}

export function visibleDrivePath(view: DriveView | undefined, path: string): string {
  if (!view) return path
  for (const [host, visible] of [
    [view.chat?.path, '/drive/ChatDrive'],
    [view.library.path, '/drive'],
    [view.scope.path, '/drive'],
    [view.recovery, '/drive-recovery']
  ]) {
    if (host && pathIsWithin(host, path)) return visible + path.slice(host.length)
  }
  return path
}
