import type { Slots } from './lifecycle_messages'
import { create } from '@bufbuild/protobuf'
import { isRecord, type JsonObject } from '@agentbull/active-support'
import type { BrowserRuntime } from '../browser-runtime'
import { startRunCLIBridges } from '../cli/run-cli-bridges'
import { agentHomePaths } from '../core/agent-home-paths'
import { materializeAgentLibraryDocuments } from '../core/agent-library-documents'
import { prepareExecutionMaterials, type PreparedExecutionMaterials } from '../core/execution/execution-materials'
import type { ContentPart, WorkerAgentTool } from '../core/types'
import { imageBytes } from '../common/image-bytes'
import { Drive } from '../drive/drive'
import {
  createEnvelope,
  envelopeHeader,
  fetchRuntimeConfigFromProto,
  jsonBytes,
  ToolProgressSchema,
  ToolResultSchema,
  ToolStatusSchema,
  WorkspaceReadySchema,
  safeNumberFromBigInt,
  type Envelope
} from '../fabric/envelope_proto'
import type { EnvelopeSender } from '../fabric/fabric'
import type {
  RunRef as RunRefMessage,
  WorkspaceOpen,
  ToolCall,
  ToolCancel,
  WorkspaceClose
} from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { WorkspaceReady_Reason } from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import { runRefFromProto } from '../lanes/session_lane'
import type { RuntimeRPCClient } from '../lanes/rpc_lane'
import { materializeSkills } from '../skills/drive_skills'
import { createComputerTools } from '../tools/computer'
import { loadEnabledSkillMCPServers } from '../tools/mcp'
import { renderedFallbackFetch } from '../tools/web/web-tools'
import { errorMessage } from '../common/errors'
import type { WorkerConfig } from './config'
import type { WorkerDrainState } from './drain'
import { throwingRPCRequester } from './rpc_requests'
import { prepareActorWorkspace } from './workspace'
import { workerLogger } from './logging'

type Result = {
  content: ContentPart[]
  details?: unknown
  isError?: boolean
  failureKind?: string
}
type Call = { abort: AbortController; result?: Result; promise: Promise<void> }
type Workspace = {
  run: RunRefMessage
  ready: Promise<void>
  tools: WorkerAgentTool[]
  calls: Map<string, Call>
  idleMs: number
  timer?: ReturnType<typeof setTimeout>
  touchedAt: number
  closing: boolean
  materials?: PreparedExecutionMaterials
  closeBridge?: () => void
  closed: Promise<void>
  finish: () => void
}

/** Owns disposable workspaces and call receipts until close or idle expiry. */
export class Workspaces {
  private readonly spaces = new Map<string, Workspace>()
  constructor(
    private readonly config: WorkerConfig,
    private readonly browser: BrowserRuntime,
    private readonly send: EnvelopeSender,
    private readonly rpcClient: RuntimeRPCClient,
    private readonly drain: WorkerDrainState,
    private readonly slots: Slots
  ) {}
  get size(): number {
    return this.spaces.size
  }

  beginDrain(): void {
    for (const space of this.spaces.values()) this.touch(space)
  }

  open(input: WorkspaceOpen): void {
    const run = runRefFromProto(input.run)
    const key = run.session.session_id
    const old = this.spaces.get(key)
    if (old) {
      if (old.closing) {
        this.drain.track(old.closed.then(() => this.open(input)))
      } else if (old.run.signalId !== run.signal_id) {
        this.drain.track(
          this.close({ run: old.run } as WorkspaceClose)
            .then(() => this.open(input))
            .catch(error => this.ready(input.run!, errorMessage(error), WorkspaceReady_Reason.PREPARATION_FAILED))
        )
      } else {
        this.touch(old)
        this.drain.track(
          old.ready.then(() => this.ready(input.run!)).catch(error => this.ready(input.run!, errorMessage(error)))
        )
      }
      return
    }
    if (!this.drain.acceptsTurns || !this.slots.reserve()) {
      void this.ready(
        input.run!,
        'Worker has no available workspace slot.',
        this.drain.acceptsTurns ? WorkspaceReady_Reason.CAPACITY : WorkspaceReady_Reason.DRAINING
      )
      return
    }
    let finish!: () => void
    const closed = this.drain.track(
      new Promise<void>(resolve => {
        finish = resolve
      })
    )
    const space: Workspace = {
      run: input.run!,
      ready: Promise.resolve(),
      tools: [],
      calls: new Map(),
      idleMs: safeNumberFromBigInt(input.idleTimeoutMs, 'workspace_open.idle_timeout_ms'),
      touchedAt: Date.now(),
      closing: false,
      closed,
      finish
    }
    this.spaces.set(key, space)
    space.ready = this.prepare(input, space)
    this.drain.track(
      space.ready
        .then(async () => {
          await this.ready(space.run)
          this.touch(space)
        })
        .catch(async error => {
          await this.ready(space.run, errorMessage(error))
          await this.close({ run: input.run } as WorkspaceClose)
        })
    )
    void this.slots.publish()
  }

  call(input: ToolCall): void {
    const run = runRefFromProto(input.run)
    const space = this.spaces.get(run.session.session_id)
    if (!space || space.closing || space.run.signalId !== run.signal_id) {
      void this.status(input, 'unknown')
      return
    }
    this.touch(space)
    const key = callKey(input)
    const existing = space.calls.get(key)
    if (existing) {
      if (existing.result) void this.result(input, existing.result)
      return
    }
    if (input.mode === 'probe') {
      void this.status(input, 'unknown')
      return
    }
    const call: Call = { abort: new AbortController(), promise: Promise.resolve() }
    space.calls.set(key, call)
    call.promise = this.drain.track(
      space.ready
        .then(async () => {
          call.abort.signal.throwIfAborted()
          const result = await this.execute(space, input, call.abort.signal)
          call.result = result
          await this.result(input, result)
        })
        .catch(async error => {
          call.result = {
            content: [
              {
                type: 'text',
                text: `Error: ${errorMessage(error)}\nAnalyze the error above and try a different approach.`
              }
            ],
            isError: true,
            failureKind: 'runtime_error'
          }
          await this.result(input, call.result)
        })
        .catch(error =>
          workerLogger.warning('worker.tool_result_send_failed', 'Tool result remains available for adoption', {
            call_id: input.callId,
            error: errorMessage(error)
          })
        )
        .finally(() => this.touch(space))
    )
  }

  cancel(input: ToolCancel): void {
    const run = runRefFromProto(input.run)
    const space = this.spaces.get(run.session.session_id)
    if (space?.run.signalId === run.signal_id) {
      space.calls.get(callKey(input))?.abort.abort(new Error('Tool execution was canceled.'))
    }
  }

  async close(input: WorkspaceClose): Promise<void> {
    const run = runRefFromProto(input.run)
    const space = this.spaces.get(run.session.session_id)
    if (!space || space.run.signalId !== run.signal_id || space.closing) return
    space.closing = true
    if (space.timer) clearTimeout(space.timer)
    for (const call of space.calls.values()) if (!call.result) call.abort.abort(new Error('Workspace closed.'))
    try {
      await Promise.allSettled([...space.calls.values()].map(call => call.promise))
      await space.ready.catch(() => undefined)
      space.closeBridge?.()
      await space.materials?.cleanup()
    } finally {
      this.spaces.delete(run.session.session_id)
      this.slots.release()
      space.finish()
      await this.slots.publish()
    }
  }

  private async prepare(input: WorkspaceOpen, space: Workspace): Promise<void> {
    const started = performance.now()
    const run = runRefFromProto(input.run)
    const workspace = prepareActorWorkspace(
      this.config,
      safeNumberFromBigInt(input.workspaceId, 'workspace_open.workspace_id')
    )
    const paths = agentHomePaths(this.config.agentHomeRoot)
    const rpc = throwingRPCRequester(this.rpcClient)
    const drive = new Drive({ agentHome: paths.home, rpc })
    await materializeSkills(drive, paths.installedSkills)
    if (!input.agentContext) throw new Error('Workspace preparation requires the Agent document snapshot')
    const context = materializeAgentLibraryDocuments(paths, input.agentContext)
    const mcpServers = await loadEnabledSkillMCPServers({
      enabledSkills: context.skills,
      skillRoots: {
        builtinSkillsRoot: this.config.builtinSkillsRoot,
        agentInstalledSkillsRoot: paths.installedSkills,
        internalSkillsRoot: this.config.internalSkillsRoot
      },
      runtime: 'main'
    })
    const fetchConfig = fetchRuntimeConfigFromProto(input.fetchRuntimeConfig, 'workspace_open.fetch_runtime_config')
    const cliBridges = startRunCLIBridges({ drive, rpc, turn: run, workspaceRoot: workspace })
    space.closeBridge = cliBridges.close
    space.materials = await prepareExecutionMaterials({
      agentHome: paths.home,
      rpc,
      bindingName: input.bindingName,
      runtimeEnv: { ...input.runtimeEnv, ...cliBridges.env },
      mcpServers,
      renderedFetch: { config: fetchConfig, browserRuntime: this.browser }
    })
    space.tools = createComputerTools({
      agentHome: paths.home,
      workspaceRoot: workspace,
      drive,
      workerEnv: space.materials.workerEnv,
      runtimeEnv: space.materials.runtimeEnv
    })
    workerLogger.info('worker.workspace_prepared', 'Workspace preparation completed', {
      session_id: run.session.session_id,
      signal_id: run.signal_id,
      duration_ms: Math.round(performance.now() - started)
    })
  }

  private async execute(space: Workspace, input: ToolCall, signal: AbortSignal): Promise<Result> {
    let args: unknown
    try {
      args = JSON.parse(new TextDecoder().decode(input.argumentsJson))
    } catch {
      return invalidArguments('Expected JSON arguments.')
    }
    if (input.name === '__rendered_web_fetch') {
      if (!isRecord(args) || !Array.isArray(args.urls) || !args.urls.every(url => typeof url === 'string')) {
        return invalidArguments('urls must be a list of URLs.')
      }
      // Preparation binds rendered fetch. Close waits for calls before material cleanup.
      const value = await renderedFallbackFetch(args.urls as string[], space.materials!.renderedFetch!, signal)
      return { content: [{ type: 'text', text: JSON.stringify(value) }], details: value }
    }
    const tool = space.tools.find(
      tool => tool.name === input.name && normalizeNamespace(input.namespace) === 'functions'
    )
    if (!tool) return invalidArguments(`Unknown environment tool ${input.name}.`)
    const parsed = tool.schema.safeParse(args)
    if (!parsed.success) return invalidArguments(parsed.error.message)
    const activity = tool.describeActivity(parsed.data)
    if (activity) {
      await this.progress(input, {
        kind: 'tool.activity',
        payload: { operation_id: input.callId, phase: 'running', activity }
      })
    }
    const value = await tool.execute(input.callId, parsed.data, signal)
    const completed = tool.describeCompletedActivity?.(parsed.data, value.details) ?? activity
    if (completed) {
      await this.progress(input, {
        kind: 'tool.activity',
        payload: { operation_id: input.callId, phase: 'completed', activity: completed }
      })
    }
    return {
      content: value.content,
      details: value.details,
      isError: value.isError,
      failureKind: value.failureKind
    }
  }

  private touch(space: Workspace): void {
    space.touchedAt = Date.now()
    if (space.timer) clearTimeout(space.timer)
    if (!this.drain.acceptsTurns && !space.closing && [...space.calls.values()].every(call => call.result)) {
      this.closeInBackground(space)
      return
    }
    if (!space.closing && space.idleMs > 0) {
      space.timer = setTimeout(() => {
        if ([...space.calls.values()].some(call => !call.result)) {
          this.touch(space)
          return
        }
        this.closeInBackground(space)
      }, space.idleMs)
      space.timer.unref?.()
    }
  }
  private closeInBackground(space: Workspace): void {
    this.drain.track(
      this.close({ run: space.run } as WorkspaceClose).catch(error => {
        workerLogger.warning('worker.workspace_close_failed', 'Workspace cleanup failed', {
          error: errorMessage(error)
        })
      })
    )
  }

  private ready(
    run: RunRefMessage,
    error?: string,
    reason = error ? WorkspaceReady_Reason.PREPARATION_FAILED : WorkspaceReady_Reason.READY
  ): Promise<void> {
    return this.publish(
      createEnvelope({
        ...envelopeHeader(`workspace-ready-${crypto.randomUUID()}`),
        body: { case: 'workspaceReady', value: create(WorkspaceReadySchema, { run, error, reason }) }
      })
    )
  }
  private status(input: ToolCall, state: string): Promise<void> {
    return this.publish(
      createEnvelope({
        ...envelopeHeader(`tool-status-${crypto.randomUUID()}`),
        body: {
          case: 'toolStatus',
          value: create(ToolStatusSchema, { run: input.run, responseId: input.responseId, callId: input.callId, state })
        }
      })
    )
  }
  private result(input: ToolCall, result: Result): Promise<void> {
    return this.publish(
      createEnvelope({
        ...envelopeHeader(`tool-result-${crypto.randomUUID()}`),
        body: {
          case: 'toolResult',
          value: create(ToolResultSchema, {
            run: input.run,
            responseId: input.responseId,
            callId: input.callId,
            contentJson: jsonBytes(result.content.filter(part => part.type === 'text')),
            images: result.content
              .filter(part => part.type === 'image')
              .map(part => imageBytes(part.image) ?? new Uint8Array()),
            detailsJson: jsonBytes(result.details as JsonObject),
            isError: result.isError,
            failureKind: result.failureKind
          })
        }
      })
    )
  }
  private async publish(envelope: Envelope): Promise<void> {
    try {
      await this.send(envelope)
    } catch (error) {
      // Execution facts remain in the workspace. A new Driver can ask again.
      workerLogger.warning('worker.workspace_notification_failed', 'Workspace notification could not be sent', {
        frame: envelope.body.case,
        error: errorMessage(error)
      })
    }
  }
  private async progress(input: ToolCall, event: JsonObject): Promise<void> {
    try {
      await this.send(
        createEnvelope({
          ...envelopeHeader(`tool-progress-${crypto.randomUUID()}`),
          body: {
            case: 'toolProgress',
            value: create(ToolProgressSchema, {
              run: input.run,
              responseId: input.responseId,
              callId: input.callId,
              presentationJson: jsonBytes(event)
            })
          }
        })
      )
    } catch {
      /* Progress cannot change tool execution. */
    }
  }
}

function invalidArguments(message: string): Result {
  return {
    content: [
      {
        type: 'text',
        text: `Error: Invalid arguments: ${message}\nAnalyze the error above and try a different approach.`
      }
    ],
    isError: true,
    failureKind: 'invalid_arguments'
  }
}
function normalizeNamespace(value?: string): string {
  return !value || value === 'functions' ? 'functions' : value
}
function callKey(input: Pick<ToolCall, 'responseId' | 'callId'>): string {
  return JSON.stringify([input.responseId, input.callId])
}
