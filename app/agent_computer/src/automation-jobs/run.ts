import { isRecord, safeJsonParse } from '@agentbull/active-support'
import { existsSync, realpathSync, rmSync, unlinkSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { errorMessage } from '../common/errors'
import { mkdirAgent } from '../common/agent-user'
import { writeFileAtomicSync } from '../common/atomic-write'
import { jsonBytes, jsonObjectFromBytes } from '../fabric/envelope_proto'
import { agentHomePaths, WORKER_SHARE_ROOT } from '../core/agent-home-paths'
import { startDriveCLIBridge } from '../cli/drive/drive-cli-bridge'
import { startPodCLIBridge } from '../cli/pod/pod-cli-bridge'
import { DRIVE_CLI_SOCKET_ENV, POD_CLI_SOCKET_ENV } from '../core/execution/turn_runtime_env'
import { Drive } from '../drive/drive'
import { downloadFolder } from '../drive/folder-sync'
import { materializeSkills } from '../skills/drive_skills'
import { startSocketLineBridge, type SocketLineBridge } from '../core/socket-line-bridge'
import { prepareExecutionMaterials } from '../core/execution/execution-materials'
import { commandEnv } from '../core/execution/command-env'
import commandProcess from '../tools/computer/command-process.py' with { type: 'text' }
import { agentProcessArgv } from '../core/execution/process-group'
import { loadEnabledSkillMCPServers } from '../tools/mcp'
import {
  type AutomationJobRunRequest,
  type AutomationJobRunResponse
} from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { type RPCRequester } from '../lanes/rpc_lane'
import type { AgentHomeConfig, WorkerConfig } from '../worker/config'

const logMaxBytes = 65_536
const emitRequestMaxBytes = 1_100_000
const workerSDKPath = join(import.meta.dir, 'sdk.ts')
const contextFileEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_CONTEXT_FILE'
const emitSocketEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_EMIT_SOCKET'

type RunResult = Omit<AutomationJobRunResponse, '$typeName'>
type AutomationRunConfig = Pick<WorkerConfig, 'agentHomeRoot' | 'builtinSkillsRoot' | 'internalSkillsRoot'>
type AutomationRunOptions = {
  config: AutomationRunConfig
  rpc: RPCRequester
  /** SDK module to preload; the default is the installed Worker SDK. */
  sdkPath?: string
  signal?: AbortSignal
  deadlineUnixMs?: number
}

/**
 * Runs one control-plane-claimed automation attempt on the Agent's Worker.
 *
 * The script lives in the Agent's drive. Each attempt copies its folder to a
 * fresh run directory in the Agent Home, runs `main.ts` there, and removes the
 * directory afterwards. The file list and each downloaded digest must agree
 * before execution starts. Installed Skills are copied under the same run root
 * so another run cannot replace them during this execution.
 *
 * A folder without `main.ts` or an invalid Skill MCP
 * declaration fails the run. A drive, control-plane, or disk failure before
 * the script starts throws instead, so the control plane retries the attempt
 * as an infrastructure failure.
 */
export async function runAutomationJob(
  request: AutomationJobRunRequest,
  opts: AutomationRunOptions
): Promise<RunResult> {
  const deadlineUnixMs = Math.min(Date.now() + Math.max(1, request.timeoutMs), opts.deadlineUnixMs ?? Infinity)
  const budget = new AbortController()
  const signal = AbortSignal.any([budget.signal, ...(opts.signal ? [opts.signal] : [])])
  const timer = setTimeout(
    () => budget.abort(new DOMException('Automation job budget expired', 'TimeoutError')),
    Math.max(0, deadlineUnixMs - Date.now())
  )
  const rpc: RPCRequester = (method, payload, frame, options) => {
    signal.throwIfAborted()
    const remaining = deadlineUnixMs - Date.now()
    if (remaining <= 0) throw new DOMException('Automation job budget expired', 'TimeoutError')
    return opts.rpc(method, payload, frame, {
      ...options,
      timeoutMs: Math.min(remaining, options?.timeoutMs ?? Infinity),
      signal: options?.signal ? AbortSignal.any([signal, options.signal]) : signal
    })
  }
  let execution: RunExecution | undefined
  let runRoot: string | undefined
  try {
    signal.throwIfAborted()
    if (deadlineUnixMs <= Date.now()) throw new DOMException('Automation job budget expired', 'TimeoutError')
    const paths = agentHomePaths(opts.config.agentHomeRoot)
    const agentHome = realpathSync(paths.home)
    runRoot = join(automationRunsRoot(agentHome), request.attemptId)
    const directoryPath = join(runRoot, 'script')
    const skillsRoot = join(runRoot, 'skills')
    const drive = new Drive({
      agentHome,
      rpc,
      automationAttempt: {
        jobId: String(request.automationJobId),
        runId: String(request.automationJobRunId),
        attemptId: request.attemptId
      }
    })
    execution = { drive, agentHome, agentInstalledSkillsRoot: skillsRoot, directoryPath, started: false }

    await mkdirAgent(directoryPath)
    const files = await downloadFolder(drive, request.drivePrefix, directoryPath)
    if (!files.some(file => file.path === `${request.drivePrefix}/main.ts`)) {
      return failedResult(`automation job main.ts is missing from ${request.drivePrefix} in the drive`)
    }

    await materializeSkills(drive, paths.installedSkills, skillsRoot)

    signal.throwIfAborted()
    return await runPreparedJob(request, execution, { ...opts, rpc, signal, deadlineUnixMs })
  } catch (error) {
    throw Object.assign(new Error(errorMessage(error), { cause: error }), {
      code: execution?.started ? 'automation_result_unknown' : 'automation_preparation_failed'
    })
  } finally {
    try {
      if (runRoot) await rm(runRoot, { recursive: true, force: true })
    } finally {
      clearTimeout(timer)
    }
  }
}

/**
 * Removes the run directories that a former Worker process left when it ended
 * during a run. It runs after admission, before the Worker handles a run.
 */
export function removeAbandonedRunDirectories(config: AgentHomeConfig): void {
  rmSync(automationRunsRoot(agentHomePaths(config.agentHomeRoot).home), {
    recursive: true,
    force: true
  })
}

function automationRunsRoot(agentHome: string): string {
  return join(agentHome, '.ankole', 'automation-runs')
}

async function runPreparedJob(
  request: AutomationJobRunRequest,
  execution: RunExecution,
  opts: AutomationRunOptions
): Promise<RunResult> {
  let skillMCPServers: Awaited<ReturnType<typeof loadEnabledSkillMCPServers>>

  try {
    skillMCPServers = await loadEnabledSkillMCPServers({
      enabledSkills: request.skills,
      skillRoots: {
        builtinSkillsRoot: opts.config.builtinSkillsRoot,
        agentInstalledSkillsRoot: execution.agentInstalledSkillsRoot,
        ...(opts.config.internalSkillsRoot ? { internalSkillsRoot: opts.config.internalSkillsRoot } : {})
      }
    })
  } catch (error) {
    return failedResult(errorMessage(error))
  }

  const materials = await prepareExecutionMaterials({
    abortSignal: opts.signal,
    agentHome: execution.agentHome,
    rpc: opts.rpc,
    bindingName: request.bindingName,
    mcpServers: skillMCPServers
  })
  const contextPath = join(WORKER_SHARE_ROOT, `ankole-aj-context-${randomUUID()}.json`)

  let driveBridge: SocketLineBridge | undefined
  let podBridge: SocketLineBridge | undefined
  let emitBridge: SocketLineBridge | undefined
  try {
    driveBridge = startDriveCLIBridge({ drive: execution.drive, workspaceRoot: execution.directoryPath })
    podBridge = startPodCLIBridge({
      drive: execution.drive,
      rpc: opts.rpc,
      automationAttempt: {
        jobId: String(request.automationJobId),
        runId: String(request.automationJobRunId),
        attemptId: request.attemptId
      }
    })
    emitBridge = startEmitBridge(request, opts.rpc)
    try {
      writeFileAtomicSync(
        contextPath,
        JSON.stringify({
          event: jsonObjectFromBytes(request.eventJson, 'automation_job.run event_json'),
          job: {
            id: Number(request.automationJobId),
            label: request.label
          }
        }),
        0o600
      )

      return await runProcess(
        request,
        execution,
        materials.workerEnv,
        contextPath,
        emitBridge.socketPath,
        {
          ...materials.runtimeEnv,
          [DRIVE_CLI_SOCKET_ENV]: driveBridge.socketPath,
          [POD_CLI_SOCKET_ENV]: podBridge.socketPath
        },
        opts.sdkPath ?? workerSDKPath,
        opts.signal,
        opts.deadlineUnixMs
      )
    } finally {
      emitBridge.close()
      if (existsSync(contextPath)) unlinkSync(contextPath)
    }
  } finally {
    driveBridge?.close()
    podBridge?.close()
    await materials.cleanup()
  }
}

type RunExecution = {
  drive: Drive
  started: boolean
  agentHome: string
  agentInstalledSkillsRoot: string
  directoryPath: string
}

async function runProcess(
  request: AutomationJobRunRequest,
  execution: RunExecution,
  workerEnv: Record<string, string>,
  contextPath: string,
  socketPath: string,
  executionRuntimeEnv: Record<string, string>,
  sdkPath: string,
  signal?: AbortSignal,
  deadlineUnixMs?: number
): Promise<RunResult> {
  const timeoutMs = Math.max(1, request.timeoutMs)
  const env = commandEnv(undefined, {
    agentHome: execution.agentHome,
    workerEnv,
    runtimeEnv: {
      [contextFileEnv]: contextPath,
      [emitSocketEnv]: socketPath,
      ...executionRuntimeEnv
    }
  })
  signal?.throwIfAborted()
  const python = Bun.which('python3')
  if (!python) throw new Error('Automation jobs require Python 3')
  if (deadlineUnixMs !== undefined && Date.now() >= deadlineUnixMs) {
    throw new DOMException('Automation job budget expired', 'TimeoutError')
  }
  // The existing foreground owner pins the group leader until every terminal
  // path has killed descendants. Output EOF is no longer the completion owner.
  execution.started = true
  const proc = Bun.spawn(
    agentProcessArgv([python, '-I', '-S', '-c', commandProcess, '0', 'bun', '--preload', sdkPath, 'main.ts']),
    {
      cwd: execution.directoryPath,
      env,
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe',
      detached: true
    }
  )

  const abort = () => proc.kill('SIGTERM')
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  const drain = new AbortController()
  const output = Promise.all([
    readBoundedTail(proc.stdout, logMaxBytes, drain.signal),
    readBoundedTail(proc.stderr, logMaxBytes, drain.signal)
  ])
  void output.catch(abort)
  let drainTimer: ReturnType<typeof setTimeout> | undefined
  try {
    const exitCode = await proc.exited
    drainTimer = setTimeout(() => drain.abort(), 1_000)
    const [stdout, stderr] = await output
    const timedOut = signal?.aborted && signal.reason?.name === 'TimeoutError'
    const stdoutText = stdout.bytes.toString('utf8')
    const stderrText = stderr.bytes.toString('utf8')
    if (!timedOut && exitCode === 0) {
      return {
        status: 'succeeded',
        exitCode: 0,
        error: '',
        stdout: stdoutText,
        stderr: stderrText,
        stdoutTruncated: stdout.truncated,
        stderrTruncated: stderr.truncated
      }
    }

    const error = timedOut
      ? `automation job timed out after ${timeoutMs} ms`
      : signal?.aborted
        ? 'automation job cancelled'
        : failureSummary(stderrText) || `automation job exited with code ${exitCode}`

    return {
      status: 'failed',
      exitCode: timedOut ? 124 : (exitCode ?? 1),
      error,
      stdout: stdoutText,
      stderr: stderrText,
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated
    }
  } finally {
    if (drainTimer) clearTimeout(drainTimer)
    signal?.removeEventListener('abort', abort)
    if (proc.exitCode === null) {
      abort()
      await proc.exited
    }
    drain.abort()
    await output.catch(() => undefined)
  }
}

export function startEmitBridge(
  request: AutomationJobRunRequest,
  rpc: RPCRequester,
  socketRoot = WORKER_SHARE_ROOT
): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(socketRoot, `ankole-aj-emit-${randomUUID()}.sock`),
    maxRequestBytes: emitRequestMaxBytes,
    oversizeError: 'Automation request is too large',
    handleLine: line => emitLine(line, request, rpc)
  })
}

async function emitLine(line: string, request: AutomationJobRunRequest, rpc: RPCRequester): Promise<unknown> {
  const command = safeJsonParse(line).unwrapOr(undefined)
  if (!isRecord(command)) throw new Error('Invalid JSON request')
  if (!Object.hasOwn(command, 'payload')) {
    throw new Error('emitEvent request is missing payload')
  }

  await rpc(
    'automation_job.emit',
    {
      automationJobRunId: request.automationJobRunId,
      attemptId: request.attemptId,
      payloadJson: jsonBytes(command.payload as never)
    },
    undefined
  )
  return { ok: true, result: {} }
}

async function readBoundedTail(
  stream: ReadableStream<Uint8Array> | null,
  maxBytes: number,
  signal?: AbortSignal
): Promise<{ bytes: Buffer; truncated: boolean }> {
  if (!stream) return { bytes: Buffer.alloc(0), truncated: false }

  const reader = stream.getReader()
  const abort = () => {
    void reader.cancel().catch(() => undefined)
  }
  signal?.addEventListener('abort', abort, { once: true })
  let retained = Buffer.alloc(0)
  let totalBytes = 0

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break

      const chunk = Buffer.from(value)
      totalBytes += chunk.length
      if (chunk.length >= maxBytes) {
        retained = chunk.subarray(chunk.length - maxBytes)
      } else {
        retained = Buffer.concat([retained, chunk])
        if (retained.length > maxBytes) retained = retained.subarray(retained.length - maxBytes)
      }
    }

    return { bytes: retained, truncated: totalBytes > maxBytes || signal?.aborted === true }
  } finally {
    signal?.removeEventListener('abort', abort)
    reader.releaseLock()
  }
}

function failedResult(error: string): RunResult {
  return {
    status: 'failed',
    exitCode: 1,
    error,
    stdout: '',
    stderr: '',
    stdoutTruncated: false,
    stderrTruncated: false
  }
}

function failureSummary(value: string): string | undefined {
  const lines = value
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
  const runtimeError = lines.find(line => /^error:\s*\S/i.test(line))
  return runtimeError || lines[0]
}
