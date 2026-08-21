import { realpathSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { pathIsWithin } from '../../core/path-boundary'
import {
  startSocketLineBridge,
  type SocketLineBridge,
  type SocketLineBridgeResponse
} from '../../core/socket-line-bridge'
import { rpcMethods, type AutomationJobRPCRequester } from '../../lanes/rpc_lane'
import { AutomationJobCLICommand } from './automation-job-cli-protocol'

const maxCommandBytes = 16 * 1024

/**
 * Starts the turn-local bridge for automation job management CLIs.
 */
export function startAutomationJobCLIBridge(opts: {
  agentHome: string
  requestAutomationJobRPC: AutomationJobRPCRequester
  socketRoot?: string
}): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-aj-${randomUUID()}.sock`),
    maxRequestBytes: maxCommandBytes,
    oversizeError: 'automation job CLI request is too large',
    handleLine: line => executeLine(line, opts)
  })
}

async function executeLine(
  line: string,
  opts: {
    agentHome: string
    requestAutomationJobRPC: AutomationJobRPCRequester
  }
): Promise<SocketLineBridgeResponse> {
  let raw: unknown

  try {
    raw = JSON.parse(line)
  } catch {
    return { ok: false, error: 'automation job CLI request must be one JSON object' }
  }

  const parsed = AutomationJobCLICommand.safeParse(raw)
  if (!parsed.success) {
    return { ok: false, error: parsed.error.issues.map(issue => issue.message).join('; ') }
  }

  const command = parsed.data
  const call = opts.requestAutomationJobRPC

  if (command.operation === 'create') {
    const directoryPath = validatedJobDirectory(opts.agentHome, command.cwd, command.directory_path)
    const result = await call(rpcMethods.automationJobCreate, {
      directoryPath,
      label: command.label,
      wakeOnFailure: command.wake_on_failure
    })
    return { ok: true, result }
  }

  if (command.operation === 'list') {
    const result = await call(rpcMethods.automationJobList, command.limit ? { limit: command.limit } : {})
    return { ok: true, result }
  }

  if (command.operation === 'show') {
    const result = await call(rpcMethods.automationJobShow, {
      automationJobId: String(command.automation_job_id),
      ...(command.runs ? { runs: command.runs } : {})
    })
    return { ok: true, result }
  }

  const result = await call(rpcMethods.automationJobCancel, {
    automationJobId: String(command.automation_job_id)
  })
  return { ok: true, result }
}

export function validatedJobDirectory(agentHome: string, cwd: string, requestedPath: string): string {
  const home = realpathSync(agentHome)
  const candidate = realpathSync(resolve(cwd, requestedPath))

  if (!pathIsWithin(home, candidate)) {
    throw new Error('automation job directory must resolve inside the current Agent Home')
  }
  if (!statSync(candidate).isDirectory()) {
    throw new Error('automation job path must resolve to a directory')
  }

  const entrypoint = realpathSync(join(candidate, 'main.ts'))
  if (!pathIsWithin(candidate, entrypoint)) {
    throw new Error('automation job main.ts must resolve inside the job directory')
  }
  if (!statSync(entrypoint).isFile()) {
    throw new Error('automation job directory must contain a main.ts file')
  }

  return candidate
}
