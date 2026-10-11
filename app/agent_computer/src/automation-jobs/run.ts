import { existsSync, realpathSync, rmSync, unlinkSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { errorMessage } from '../common/errors'
import { mkdirAgent } from '../common/agent-user'
import { writeFileAtomicSync } from '../common/atomic-write'
import { jsonBytes, jsonObjectFromBytes } from '../fabric/envelope_proto'
import { agentHomePaths, WORKER_SHARE_ROOT } from '../core/agent-home-paths'
import { Drive } from '../drive/drive'
import { downloadFolder } from '../drive/folder-sync'
import { materializeSkills } from '../skills/drive_skills'
import { startSocketLineBridge, type SocketLineBridge } from '../core/socket-line-bridge'
import { prepareExecutionMaterials } from '../core/execution/execution-materials'
import { commandEnv } from '../core/execution/command-env'
import { agentProcessArgv, killProcessGroup } from '../core/execution/process-group'
import { loadEnabledSkillMCPServers } from '../tools/mcp'
import { type AutomationJobRunRequest, type AutomationJobRunResponse, type RPCRequester } from '../lanes/rpc_lane'
import type { AgentHomeConfig, WorkerConfig } from '../worker/config'

const logMaxBytes = 65_536
const emitRequestMaxBytes = 1_100_000
const workerSDKPath = '/repo/app/agent_computer/src/automation-jobs/sdk.ts'
const contextFileEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_CONTEXT_FILE'
const emitSocketEnv = 'ANKOLE_RUNTIME_AUTOMATION_JOB_EMIT_SOCKET'

type RunResult = Omit<AutomationJobRunResponse, '$typeName'>
type AutomationRunConfig = Pick<WorkerConfig, 'agentHomeRoot' | 'builtinSkillsRoot' | 'internalSkillsRoot'>
type AutomationRunOptions = {
  config: AutomationRunConfig
  rpc: RPCRequester
  /** SDK module to preload; the default is the installed Worker SDK. */
  sdkPath?: string
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
  const paths = agentHomePaths(opts.config.agentHomeRoot)
  const agentHome = realpathSync(paths.home)
  const runRoot = join(automationRunsRoot(agentHome), request.attemptId)
  const directoryPath = join(runRoot, 'script')
  const skillsRoot = join(runRoot, 'skills')
  const drive = new Drive({ agentHome, rpc: opts.rpc })

  try {
    await mkdirAgent(directoryPath)
    const files = await downloadFolder(drive, request.drivePrefix, directoryPath)
    if (!files.some(file => file.path === `${request.drivePrefix}/main.ts`)) {
      return failedResult(`automation job main.ts is missing from ${request.drivePrefix} in the drive`)
    }

    await materializeSkills(drive, paths.installedSkills, skillsRoot)

    return await runPreparedJob(request, { agentHome, agentInstalledSkillsRoot: skillsRoot, directoryPath }, opts)
  } finally {
    await rm(runRoot, { recursive: true, force: true })
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
    agentHome: execution.agentHome,
    rpc: opts.rpc,
    bindingName: request.bindingName,
    mcpServers: skillMCPServers
  })
  const contextPath = join(WORKER_SHARE_ROOT, `ankole-aj-context-${randomUUID()}.json`)

  try {
    const emitBridge = startEmitBridge(request, opts.rpc)
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
        materials.runtimeEnv,
        opts.sdkPath ?? workerSDKPath
      )
    } finally {
      emitBridge.close()
      if (existsSync(contextPath)) unlinkSync(contextPath)
    }
  } finally {
    await materials.cleanup()
  }
}

type RunExecution = {
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
  sdkPath: string
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
  // Its own process group lets the timeout end every process of the script.
  const proc = Bun.spawn(agentProcessArgv(['bun', '--preload', sdkPath, 'main.ts']), {
    cwd: execution.directoryPath,
    env,
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
    detached: true
  })

  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    killProcessGroup(proc.pid)
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
    'automation_job.emit',
    {
      automationJobRunId: request.automationJobRunId,
      attemptId: request.attemptId,
      payloadJson: jsonBytes(command.payload as never)
    },
    undefined
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

function failureSummary(value: string): string | undefined {
  const lines = value
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
  const runtimeError = lines.find(line => /^error:\s*\S/i.test(line))
  return runtimeError || lines[0]
}
