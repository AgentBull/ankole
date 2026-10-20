import { lchownSync, lstatSync, mkdirSync } from 'node:fs'
import { lchown, lstat, mkdir } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

export const AGENT_UID = 1000
export const AGENT_GID = 1000

export function isRootWorker(): boolean {
  return process.platform === 'linux' && process.getuid?.() === 0
}

/** Gives a projected file, socket, or directory to the Agent user. */
export function chownAgentPathSync(path: string): void {
  if (!isRootWorker()) return
  const stat = lstatSync(path)
  // OSS mounts already expose uid 1000 and reject chown.
  if (stat.uid !== AGENT_UID || stat.gid !== AGENT_GID) lchownSync(path, AGENT_UID, AGENT_GID)
}

export async function chownAgentPath(path: string): Promise<void> {
  if (!isRootWorker()) return
  const stat = await lstat(path)
  if (stat.uid !== AGENT_UID || stat.gid !== AGENT_GID) await lchown(path, AGENT_UID, AGENT_GID)
}

/** Creates Agent-writable directories without changing existing file owners. */
export function mkdirAgentSync(path: string, mode = 0o755): void {
  const target = resolve(path)
  const firstCreated = mkdirSync(target, { recursive: true, mode })
  for (const directory of createdDirectories(target, firstCreated)) chownAgentPathSync(directory)
}

export async function mkdirAgent(path: string, mode = 0o755): Promise<void> {
  const target = resolve(path)
  const firstCreated = await mkdir(target, { recursive: true, mode })
  for (const directory of createdDirectories(target, firstCreated)) await chownAgentPath(directory)
}

export function createdDirectories(path: string, firstCreated: string | undefined): string[] {
  const target = resolve(path)
  const directories = [target]
  if (!firstCreated) return directories
  const first = resolve(firstCreated)
  if (target !== first && !target.startsWith(first === '/' ? '/' : `${first}/`)) {
    throw new Error(`Created directory ${first} is not an ancestor of ${target}`)
  }
  while (directories.at(-1) !== first) {
    const current = directories.at(-1)!
    const parent = dirname(current)
    if (parent === current) {
      throw new Error(`Created directory ${first} is not an ancestor of ${target}`)
    }
    directories.push(parent)
  }
  return directories
}
