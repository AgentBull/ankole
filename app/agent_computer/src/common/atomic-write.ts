import { randomUUID } from 'node:crypto'
import { chmodSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { chmod, rename, rm, writeFile } from 'node:fs/promises'
import { chownAgentPath, chownAgentPathSync } from './agent-user'

export async function writeFileAtomic(path: string, content: string | Uint8Array, mode: number): Promise<void> {
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`
  try {
    await writeFile(temporary, content, { mode, flag: 'wx' })
    if (mode & 0o200) await chownAgentPath(temporary)
    await chmod(temporary, mode)
    await rename(temporary, path)
  } finally {
    await rm(temporary, { force: true })
  }
}

export function writeFileAtomicSync(path: string, content: string | Uint8Array, mode: number): void {
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`
  try {
    writeFileSync(temporary, content, { mode, flag: 'wx' })
    if (mode & 0o200) chownAgentPathSync(temporary)
    chmodSync(temporary, mode)
    renameSync(temporary, path)
  } finally {
    rmSync(temporary, { force: true })
  }
}
