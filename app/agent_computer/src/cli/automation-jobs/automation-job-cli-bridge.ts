import type { JsonObject as JSONObject } from '@agentbull/active-support'
import type { RPCRequestInit } from '../../lanes/rpc_contract'
import { type RPCRequester, type RPCFrame } from '../../lanes/rpc_lane'
import type { RunRef, JobTurnRef } from '../../lanes/session_lane'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'

export type AutomationJobManagementRPCMethod =
  | 'automation_job.create'
  | 'automation_job.list'
  | 'automation_job.show'
  | 'automation_job.cancel'
export type AutomationJobRPCRequester = <M extends AutomationJobManagementRPCMethod>(
  method: M,
  payload: RPCRequestInit<M>
) => Promise<JSONObject>

/** Binds this CLI family to its caller's turn; only reads may repeat after disconnect. */
export function automationJobRPCRequester(rpc: RPCRequester, turn: JobTurnRef | RunRef): AutomationJobRPCRequester {
  const frame = 'job_id' in turn ? { jobTurn: turn } : { run: turn }
  return async (method, payload) => {
    const response = await rpc(method, payload, frame as RPCFrame<typeof method>, {
      retryOnDisconnect: method === 'automation_job.list' || method === 'automation_job.show'
    })
    return jsonObjectFromBytes(response.bodyJson, `${method} body_json`) ?? {}
  }
}

import { lstat } from 'node:fs/promises'
import { basename, join, resolve } from 'node:path'
import { randomBytes, randomUUID } from 'node:crypto'
import { errorMessage } from '../../common/errors'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import {
  CLI_REQUEST_MAX_BYTES,
  parseCLIRequest,
  startSocketLineBridge,
  type SocketLineBridge,
  type SocketLineBridgeResponse
} from '../../core/socket-line-bridge'
import { type Drive, joinDrivePath } from '../../drive/drive'
import { RPCRejectedError } from '../../lanes/rpc_lane'
import { AutomationJobCLICommand } from './automation-job-cli-protocol'

/** Keeps the drive folder name, with its random suffix, inside one 255-byte path segment. */
const maxFolderNameCodePoints = 48

export function startAutomationJobCLIBridge(opts: {
  drive: Drive
  requestAutomationJobRPC: AutomationJobRPCRequester
  socketRoot?: string
}): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-aj-${randomUUID()}.sock`),
    maxRequestBytes: CLI_REQUEST_MAX_BYTES,
    oversizeError: 'automation job CLI request is too large',
    handleLine: line => executeLine(line, opts)
  })
}

async function executeLine(
  line: string,
  opts: {
    drive: Drive
    requestAutomationJobRPC: AutomationJobRPCRequester
  }
): Promise<SocketLineBridgeResponse> {
  const command = parseCLIRequest(line, AutomationJobCLICommand, 'automation job CLI request must be one JSON object')
  const call = opts.requestAutomationJobRPC

  if (command.operation === 'create') {
    const result = await createJob(opts.drive, call, command)
    return { ok: true, result }
  }

  if (command.operation === 'list') {
    const result = await call('automation_job.list', command.limit ? { limit: command.limit } : {})
    return { ok: true, result }
  }

  if (command.operation === 'show') {
    const result = await call('automation_job.show', {
      automationJobId: String(command.automation_job_id),
      ...(command.runs ? { runs: command.runs } : {})
    })
    return { ok: true, result }
  }

  const result = await call('automation_job.cancel', {
    automationJobId: String(command.automation_job_id)
  })
  return { ok: true, result }
}

/**
 * Copies the script directory into a new drive folder under `automation/` and
 * registers the job on that folder. Only a confirmed rejection removes the
 * folder. An unknown outcome can already have committed the Job.
 */
async function createJob(
  drive: Drive,
  call: AutomationJobRPCRequester,
  command: { cwd: string; directory_path: string; label: string; wake_on_failure: boolean }
): Promise<Record<string, unknown>> {
  const directory = resolve(command.cwd, command.directory_path)
  await assertJobDirectory(directory)

  const folderName = Array.from(basename(directory)).slice(0, maxFolderNameCodePoints).join('')
  const drivePrefix = joinDrivePath('automation', `${folderName}-${randomBytes(4).toString('hex')}`)
  await drive.put(directory, drivePrefix)

  try {
    return await call('automation_job.create', {
      drivePrefix,
      label: command.label,
      wakeOnFailure: command.wake_on_failure
    })
  } catch (error) {
    // RPCLane can report a handler failure after the Job was inserted.
    if (error instanceof RPCRejectedError && error.rejection.code !== 'rpc_handler_failed') {
      await drive.remove(drivePrefix).catch(() => undefined)
      throw error
    }
    throw new Error(
      `Automation Job creation outcome is unknown: ${errorMessage(error)}. The script is kept at ${drivePrefix}. Run list-automation-jobs-cli and look for this drive_prefix before retrying create.`,
      { cause: error }
    )
  }
}

/** The drive copies regular files only, so `main.ts` must be one. */
async function assertJobDirectory(directory: string): Promise<void> {
  const directoryStat = await lstat(directory).catch(() => undefined)
  if (!directoryStat?.isDirectory()) throw new Error('automation job path must be a directory')

  const entrypoint = await lstat(join(directory, 'main.ts')).catch(() => undefined)
  if (!entrypoint?.isFile()) throw new Error('automation job directory must contain a regular main.ts file')
}
