import { chmodSync, existsSync, realpathSync, statSync, unlinkSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { pathIsWithin } from '../../core/path-boundary'
import { rpcMethods, type AutomationJobRPCRequester } from '../../lanes/rpc_lane'
import { AutomationJobCLICommand, type AutomationJobCLIResponse } from './automation-job-cli-protocol'

const maxCommandBytes = 16 * 1024

type SocketState = {
  buffer: string
  handled: boolean
}

export type AutomationJobCLIBridge = {
  socketPath: string
  close: () => void
}

/**
 * Starts the turn-local bridge for automation job management CLIs.
 */
export function startAutomationJobCLIBridge(opts: {
  agentHome: string
  requestAutomationJobRPC: AutomationJobRPCRequester
  socketRoot?: string
}): AutomationJobCLIBridge {
  const socketPath = join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-aj-${randomUUID()}.sock`)

  const listener = Bun.listen<SocketState>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: '', handled: false }
      },
      data(socket, data) {
        if (socket.data.handled) return
        socket.data.buffer += Buffer.from(data).toString('utf8')

        if (Buffer.byteLength(socket.data.buffer, 'utf8') > maxCommandBytes) {
          socket.data.handled = true
          writeResponse(socket, { ok: false, error: 'automation job CLI request is too large' })
          return
        }

        const newline = socket.data.buffer.indexOf('\n')
        if (newline < 0) return

        socket.data.handled = true
        const line = socket.data.buffer.slice(0, newline)
        void executeLine(line, opts)
          .then(response => writeResponse(socket, response))
          .catch(error => writeResponse(socket, { ok: false, error: errorMessage(error) }))
      },
      error() {
        // A closed socket is the caller-visible failure.
      }
    }
  })

  chmodSync(socketPath, 0o600)
  let closed = false

  return {
    socketPath,
    close: () => {
      if (closed) return
      closed = true
      listener.stop(true)
      if (existsSync(socketPath)) unlinkSync(socketPath)
    }
  }
}

async function executeLine(
  line: string,
  opts: {
    agentHome: string
    requestAutomationJobRPC: AutomationJobRPCRequester
  }
): Promise<AutomationJobCLIResponse> {
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

function writeResponse(socket: Bun.Socket<SocketState>, response: AutomationJobCLIResponse): void {
  socket.write(`${JSON.stringify(response)}\n`)
  socket.end()
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
