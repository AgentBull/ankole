import { mkdirAgent } from '../common/agent-user'
import { dirname, join } from 'node:path'
import { type Drive, type DriveFile, joinDrivePath, sha256File } from './drive'

/** Downloads a drive folder into an empty directory owned and removed by the caller. */
export async function downloadFolder(drive: Drive, prefix: string, localDir: string): Promise<DriveFile[]> {
  const files = filesInside(prefix, await drive.list(prefix))
  for (const [relativePath, file] of files) {
    const localPath = join(localDir, relativePath)
    await mkdirAgent(dirname(localPath))
    const materialized = await drive.get(file.path, localPath)
    await assertListedContent(file, materialized, localPath)
  }
  return files.map(([, file]) => file)
}

async function assertListedContent(listed: DriveFile, downloaded: DriveFile, localPath: string): Promise<void> {
  if (
    downloaded.sha256 !== listed.sha256 ||
    downloaded.mode !== listed.mode ||
    downloaded.size !== listed.size ||
    (await sha256File(localPath)) !== listed.sha256
  ) {
    throw new Error(`drive folder changed during download: ${listed.path}; retry preparation`)
  }
}

function folderRelativePath(prefix: string, path: string): string {
  if (prefix === '') return path
  const folder = `${joinDrivePath(prefix)}/`
  if (!path.startsWith(folder)) throw new Error(`drive file ${path} is outside folder ${prefix}`)
  return path.slice(folder.length)
}

function filesInside(prefix: string, files: DriveFile[]): Array<[string, DriveFile]> {
  return files.map(file => [folderRelativePath(prefix, file.path), file])
}
