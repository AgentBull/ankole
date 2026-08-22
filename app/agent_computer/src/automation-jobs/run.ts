import { existsSync, realpathSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { errorMessage } from '../common/errors'
import { jsonBytes, jsonObjectFromBytes } from '../fabric/envelope_proto'
import { agentHomePaths, WORKER_SHARE_ROOT } from '../core/agent-home-paths'
import { pathIsWithin } from '../core/path-boundary'
import { startSocketLineBridge, type SocketLineBridge } from '../core/socket-line-bridge'
import { materializeLarkCredential } from '../core/execution/lark-credential'
import { resolveAgentWorkerEnvParts } from '../core/execution/worker_env'
import { bubblewrapArgv } from '../sandbox/bubblewrap'
import { commandEnv } from '../sandbox/command-env'
import { loadEnabledSkillMCPServers, materializeMCPorterConfig, type MaterializedMCPorterConfig } from '../tools/mcp'
import {
  rpcMethods,
  type AutomationJobRunRequest,
  type AutomationJobRunResponse,
  type RPCRequester
} from '../lanes/rpc_lane'
import type { WorkerConfig } from '../worker/config'

const logMaxBytes = 65_536
const emitRequestMaxBytes = 1_100_000
const sdkPath = '/repo/app/agent_computer/src/automation-jobs/sdk.ts'
const contextFileEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_CONTEXT_FILE'
const emitSocketEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_EMIT_SOCKET'

type RunResult = Omit<AutomationJobRunResponse, '$typeName'>

/**
 * Runs one control-plane-claimed automation attempt in the Agent sandbox.
 */
export async function runAutomationJob(
  request: AutomationJobRunRequest,
  opts: {
    config: WorkerConfig
    rpc: RPCRequester
  }
): Promise<RunResult> {
  let execution: ValidatedExecution

  try {
    execution = validateExecution(request, opts.config)
  } catch (error) {
    return failedResult(errorMessage(error))
  }

  const resolvedWorkerEnv = await resolveAgentWorkerEnvParts(request.agentUid, opts.rpc, request.bindingName)
  const larkCredential = materializeLarkCredential({
    agentUID: request.agentUid,
    agentHome: execution.agentHome,
    rpc: opts.rpc,
    workerEnv: resolvedWorkerEnv,
    bindingName: request.bindingName
  })
  const workerEnv = larkCredential.workerEnv.vars
  const contextPath = join(WORKER_SHARE_ROOT, `ankole-aj-context-${randomUUID()}.json`)
  let mcporterConfig: MaterializedMCPorterConfig

  try {
    const skillMCPServers = await loadEnabledSkillMCPServers({
      enabledSkills: request.skills,
      skillRoots: {
        builtinSkillsRoot: opts.config.builtinSkillsRoot,
        agentInstalledSkillsRoot: execution.agentInstalledSkillsRoot,
        ...(opts.config.internalSkillsRoot ? { internalSkillsRoot: opts.config.internalSkillsRoot } : {})
      }
    })
    mcporterConfig = materializeMCPorterConfig(skillMCPServers)
  } catch (error) {
    larkCredential.cleanup()
    return failedResult(errorMessage(error))
  }

  try {
    const emitBridge = startEmitBridge(request, opts.rpc)
    try {
      writeFileSync(
        contextPath,
        JSON.stringify({
          event: execution.event,
          job: {
            id: Number(request.automationJobId),
            label: request.label
          }
        }),
        { mode: 0o600, flag: 'wx' }
      )

      return await runProcess(
        request,
        execution,
        { ...workerEnv, ...mcporterConfig.env },
        contextPath,
        emitBridge.socketPath,
        larkCredential.runtimeEnv
      )
    } finally {
      emitBridge.close()
      if (existsSync(contextPath)) unlinkSync(contextPath)
    }
  } finally {
    try {
      mcporterConfig.cleanup()
    } finally {
      larkCredential.cleanup()
    }
  }
}

type ValidatedExecution = {
  agentHome: string
  agentInstalledSkillsRoot: string
  directoryPath: string
  event: Record<string, unknown>
}

function validateExecution(request: AutomationJobRunRequest, config: WorkerConfig): ValidatedExecution {
  canonicalModelID(request.automationJobRunId, 'automation job run id')
  canonicalModelID(request.automationJobId, 'automation job id')
  if (!uuidPattern.test(request.attemptId)) throw new Error('automation job attempt id is invalid')
  if (!request.label.trim()) throw new Error('automation job label is required')

  const paths = agentHomePaths(config.agentsRoot, request.agentUid)
  const agentHome = realpathSync(paths.home)
  const directoryPath = realpathSync(request.directoryPath)
  if (!pathIsWithin(agentHome, directoryPath)) {
    throw new Error('automation job directory no longer resolves inside the Agent Home')
  }
  if (!statSync(directoryPath).isDirectory()) {
    throw new Error('automation job directory is missing')
  }

  const entrypoint = realpathSync(join(directoryPath, 'main.ts'))
  if (!pathIsWithin(directoryPath, entrypoint) || !statSync(entrypoint).isFile()) {
    throw new Error('automation job main.ts is missing or resolves outside its directory')
  }

  const event = jsonObjectFromBytes(request.eventJson, 'automation_job.run event_json')
  if (!event) throw new Error('automation job trigger event is missing')

  return { agentHome, agentInstalledSkillsRoot: paths.installedSkills, directoryPath, event }
}

async function runProcess(
  request: AutomationJobRunRequest,
  execution: ValidatedExecution,
  workerEnv: Record<string, string>,
  contextPath: string,
  socketPath: string,
  larkRuntimeEnv: Record<string, string>
): Promise<RunResult> {
  const timeoutMs = Math.max(1, request.timeoutMs)
  const env = commandEnv(undefined, {
    workerEnv,
    runtimeEnv: {
      [contextFileEnv]: contextPath,
      [emitSocketEnv]: socketPath,
      ...larkRuntimeEnv
    },
    home: execution.agentHome,
    ankoleAgentHome: execution.agentHome
  })
  const argv = bubblewrapArgv({
    workspaceRoot: execution.agentHome,
    cwd: execution.directoryPath,
    env,
    commandArgv: ['bun', '--preload', sdkPath, 'main.ts']
  })
  const proc = Bun.spawn(argv, {
    cwd: execution.directoryPath,
    env,
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe'
  })

  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    proc.kill(9)
  }, timeoutMs)

  try {
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      readBoundedTail(proc.stdout, logMaxBytes),
      readBoundedTail(proc.stderr, logMaxBytes)
    ])

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
    clearTimeout(timer)
  }
}

function startEmitBridge(request: AutomationJobRunRequest, rpc: RPCRequester): SocketLineBridge {
  return startSocketLineBridge({
    socketPath: join(WORKER_SHARE_ROOT, `ankole-aj-emit-${randomUUID()}.sock`),
    maxRequestBytes: emitRequestMaxBytes,
    oversizeError: 'emitEvent payload is too large',
    handleLine: line => emitLine(line, request, rpc).then(() => ({ ok: true }))
  })
}

async function emitLine(line: string, request: AutomationJobRunRequest, rpc: RPCRequester): Promise<void> {
  const command = JSON.parse(line) as { payload?: unknown }
  if (!Object.prototype.hasOwnProperty.call(command, 'payload')) {
    throw new Error('emitEvent request is missing payload')
  }

  await rpc(
    rpcMethods.automationJobEmit,
    {
      automationJobRunId: request.automationJobRunId,
      attemptId: request.attemptId,
      payloadJson: jsonBytes(command.payload as never)
    },
    { agentUid: request.agentUid }
  )
}

async function readBoundedTail(
  stream: ReadableStream<Uint8Array> | null,
  maxBytes: number
): Promise<{ bytes: Buffer; truncated: boolean }> {
  if (!stream) return { bytes: Buffer.alloc(0), truncated: false }

  const reader = stream.getReader()
  let retained = Buffer.alloc(0)
  let totalBytes = 0

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

  return { bytes: retained, truncated: totalBytes > maxBytes }
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

function canonicalModelID(value: string, label: string): number {
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`${label} is invalid`)
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 1000 || String(parsed) !== value) {
    throw new Error(`${label} is outside the supported range`)
  }
  return parsed
}

function failureSummary(value: string): string | undefined {
  const lines = value
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
  const runtimeError = lines.find(line => /^error:\s*\S/i.test(line))
  return runtimeError || lines[0]
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
