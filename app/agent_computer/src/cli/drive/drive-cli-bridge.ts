import { randomUUID } from 'node:crypto'
import { stat } from 'node:fs/promises'
import { basename, join, resolve } from 'node:path'
import type { TurnRPCFrame } from '../../lanes/rpc_lane'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import {
  CLI_REQUEST_MAX_BYTES,
  parseCLIRequest,
  startSocketLineBridge,
  type SocketLineBridge,
  type SocketLineBridgeResponse
} from '../../core/socket-line-bridge'
import { joinDrivePath, type Drive, type DriveFile } from '../../drive/drive'
import { DriveCLICommand } from './drive-cli-protocol'

const defaultListLimit = 200

/**
 * Starts the turn-local bridge for `ankole-files`. `workspaceRoot` is where
 * `get` writes when the command names no output path.
 */
export function startDriveCLIBridge(opts: {
  drive: Drive
  workspaceRoot: string
  socketRoot?: string
  frame?: TurnRPCFrame
}): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-files-${randomUUID()}.sock`),
    maxRequestBytes: CLI_REQUEST_MAX_BYTES,
    oversizeError: 'drive CLI request is too large',
    handleLine: line => executeLine(line, opts)
  })
}

async function executeLine(
  line: string,
  opts: { drive: Drive; workspaceRoot: string; frame?: TurnRPCFrame }
): Promise<SocketLineBridgeResponse> {
  const command = parseCLIRequest(line, DriveCLICommand, 'drive CLI request must be one JSON object')
  const drive = opts.drive

  if (command.operation === 'list') {
    const page = await drive.listPage(command.prefix, {
      limit: command.limit ?? defaultListLimit,
      ...(command.after === undefined ? {} : { after: command.after })
    })
    return {
      ok: true,
      result: {
        files: page.files.map(listedFile),
        ...(page.nextAfter ? { more: true, next_after: page.nextAfter } : {})
      }
    }
  }

  if (command.operation === 'get') {
    const target = command.output
      ? resolve(command.cwd, command.output)
      : join(opts.workspaceRoot, 'drive', ...command.path.split('/'))
    const file = await drive.get(command.path, target, { node: command.node, frame: opts.frame })
    return { ok: true, result: { ...listedFile(file), local_path: target } }
  }

  if (command.operation === 'put') {
    const localPath = resolve(command.cwd, command.local_path)
    const files = await drive.put(localPath, await putTarget(localPath, command.path))
    return { ok: true, result: { files: files.map(listedFile) } }
  }

  const deleted = await drive.remove(command.path)
  return { ok: true, result: { deleted } }
}

/**
 * A target that ends with "/" names a folder, as it does for cp: a file goes
 * into the folder under its own name, and the files of a directory go under
 * the folder.
 */
async function putTarget(localPath: string, path: string): Promise<string> {
  const folder = path.replace(/\/+$/u, '')
  if (folder === path) return path
  return (await stat(localPath)).isFile() ? joinDrivePath(folder, basename(localPath)) : folder
}

function listedFile(file: DriveFile): Record<string, unknown> {
  return {
    node_id: file.nodeId,
    object_id: file.objectId,
    path: file.path,
    size: file.size,
    content_type: file.contentType,
    source: file.source,
    updated_at: file.updatedAt
  }
}
