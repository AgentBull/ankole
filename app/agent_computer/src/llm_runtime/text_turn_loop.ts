import type { ActorInputEnvelope, JsonObject, TurnStart, TurnSteerUpdate } from '../actor_lane'
import { runAgentLoop, type AgentEvent, type AgentMessage } from '../core'
import { createAnthropic } from '../llm/providers/anthropic'
import { createGoogle } from '../llm/providers/google'
import { createOpenAI } from '../llm/providers/openai'
import { createOpenAICompatible } from '../llm/providers/openai-compatible'
import { createCombinedAbortSignal } from '../common/async'
import { getModel } from '../llm/catalog'
import type { AssistantMessage, Message, Model } from '../llm/bullx'
import type { ProviderOptions } from '../llm/provider-utils'
import type { LanguageModel } from '../llm/types'
import {
  buildCompactionHistoryUserPrompt,
  COMPACTION_FOCUS_INSTRUCTIONS,
  SUMMARIZATION_SYSTEM_PROMPT
} from '../prompts/compression-prompt'
import { buildAgentSystemPrompt, type CurrentChannelContext } from '../prompts/system_prompt'
import { visibleReplyProposal, type FinalProposalBody } from '../turn_envelopes'
import { createComputerTools } from '../tools/computer'
import { createReplyAttachmentStore, type ReplyAttachmentStore } from '../tools/computer/reply-attachment-tool'
import { createSkillTools } from '../tools/library/skill-tools'
import { createTodoTool, TodoStore } from '../tools/todo-tool'
import { runAmbientRecognizer } from './ambient_recognizer'
import {
  prependEnvironmentInfoLinesToUserMessage,
  prependPreviousChatHistoryToUserMessage,
  renderMessageWithContext
} from './message_context'
import type {
  AgentProfile,
  AgentProfileRequest,
  LlmProviderCredentialRejected,
  LlmProviderCredentialRequest,
  LlmProviderCredentialResponse,
  SkillOverlayReplaceRequest,
  SkillOverlayRequest,
  SkillOverlayResponse,
  TurnContextRequest,
  TurnRuntimeContext
} from '../rpc_lane'

export type CredentialRequester = (
  request: LlmProviderCredentialRequest
) => Promise<LlmProviderCredentialResponse | LlmProviderCredentialRejected>

export type AgentProfileRequester = (request: AgentProfileRequest) => Promise<AgentProfile>
export type TurnContextRequester = (request: TurnContextRequest) => Promise<TurnRuntimeContext>
export type SkillOverlayRequester = (request: SkillOverlayRequest) => Promise<SkillOverlayResponse>
export type SkillOverlayReplaceRequester = (request: SkillOverlayReplaceRequest) => Promise<SkillOverlayResponse>

export type TextTurnLoopOptions = {
  workspaceRoot: string
  builtinSkillsRoot?: string
  agentInstalledSkillsRoot?: string
  requestCredential: CredentialRequester
  requestAgentProfile?: AgentProfileRequester
  requestTurnContext?: TurnContextRequester
  requestSkillOverlay?: SkillOverlayRequester
  replaceSkillOverlay?: SkillOverlayReplaceRequester
  clearSkillOverlay?: SkillOverlayRequester
  runtimeContext?: TurnRuntimeContext
  agentProfile?: AgentProfile
  pollSteering?: () => TurnSteerUpdate[]
  maxSteps?: number
  extraMessages?: AgentMessage[]
}

type ConversationContext = {
  messages: AgentMessage[]
  materializedInputIds: Set<string>
  pendingUserEnvironmentInfoLines: string[]
  previousChatHistorySummaries: string[]
}

type TurnTelemetry = {
  usage?: JsonObject
  stopReason?: string
  providerMetadata: JsonObject
  toolResults: unknown[]
}

function skillRootsFromOptions(
  opts: TextTurnLoopOptions
): { builtinSkillsRoot: string; agentInstalledSkillsRoot: string } | undefined {
  if (!opts.builtinSkillsRoot || !opts.agentInstalledSkillsRoot) return undefined
  return {
    builtinSkillsRoot: opts.builtinSkillsRoot,
    agentInstalledSkillsRoot: opts.agentInstalledSkillsRoot
  }
}

const TOOL_RESULT_MAX_CHARS = 12_000
const TEXT_TURN_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_LLM_TURN_TIMEOUT_MS', 180_000)
const COMPRESSION_TURN_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_LLM_COMPRESSION_TIMEOUT_MS', 90_000)
const AMBIENT_RECOGNIZER_TIMEOUT_MS = positiveIntegerEnv('ANKOLE_LLM_AMBIENT_RECOGNIZER_TIMEOUT_MS', 45_000)

/**
 * Dispatches one worker turn by ActorInput type. These are internal Agent
 * Computer handlers: ZMQ delivered only the event batch, while recognizers and
 * follow-up generation stay inside the Agent Computer AI SDK runtime.
 */
export async function runLlmTurnHandlers(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<FinalProposalBody> {
  if (isAmbientMayInterveneTurn(turnStart)) {
    return runAmbientMayInterveneHandler(turnStart, opts)
  }

  if (isCompressionTurn(turnStart)) {
    return runCompressionTurn(turnStart, opts)
  }

  return runTextTurnLoop(turnStart, opts)
}

/**
 * Runs one Ankole text turn inside Agent Computer.
 *
 * The control plane delivers actor inputs and an opaque `model_ref`; the worker
 * resolves credentials over the parent protocol, builds the concrete BullX AI SDK
 * model inside Agent Computer, and lets BullX's reusable agent loop own tool-call/result turns.
 * This keeps credentials memory-only and keeps provider-specific behavior inside
 * the copied BullX LLM fork instead of hand-writing per-provider HTTP payloads.
 */
export async function runTextTurnLoop(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<FinalProposalBody> {
  const modelRef = turnStart.model_ref
  if (!modelRef) {
    throw new Error('LLM turn is missing a real model_ref')
  }

  const credential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: modelRef.profile,
    purpose: 'ai_turn'
  })

  if ('code' in credential) {
    throw new Error(`credential rejected: ${credential.code} ${credential.message ?? ''}`.trim())
  }

  assertCredentialMatchesTurn(modelRef, credential)

  const model = runtimeModelFromCredential(credential)
  const providerOptions = providerOptionsFromCredential(credential, model.provider)
  const telemetry = createTurnTelemetry(credential, model)
  const agentProfile = opts.agentProfile ?? (await resolveAgentProfile(turnStart, opts))
  const runtimeContext = await resolveTurnRuntimeContext(turnStart, opts)

  const conversation = conversationContextFromRuntimeContext(runtimeContext, model)
  const todoStore = new TodoStore()
  const replyAttachmentStore = createReplyAttachmentStore()
  const rawPrompts = turnStart.inputs
    .filter(input => !inputAlreadyMaterialized(input, conversation))
    .map(input => userMessage(inputText(input.payload_json, input.type)))
  const withEnvironmentInfo = attachPendingEnvironmentInfoToUserMessage(
    conversation.messages,
    rawPrompts,
    conversation.pendingUserEnvironmentInfoLines
  )
  const { messages, prompts } = attachPreviousChatHistoryToUserMessage(
    withEnvironmentInfo.messages,
    withEnvironmentInfo.prompts,
    lastNonEmpty(conversation.previousChatHistorySummaries)
  )

  const systemPrompt = buildAgentSystemPrompt({
    workspaceRoot: opts.workspaceRoot,
    turnStart,
    agentProfile,
    runtimeContext,
    currentChannel: currentChannelFromTurnStart(turnStart)
  })

  const turnTimeout = createCombinedAbortSignal(undefined, TEXT_TURN_TIMEOUT_MS)
  try {
    const newMessages = await runAgentLoop(
      prompts,
      {
        systemPrompt,
        messages: [...messages, ...(opts.extraMessages ?? [])],
        tools: [
          createTodoTool(todoStore),
          ...createComputerTools({
            agentUid: turnStart.turn.actor.agent_uid,
            conversationId: turnStart.turn.actor.session_id,
            workspaceRoot: opts.workspaceRoot,
            replyAttachmentStore
          }),
          ...createSkillTools(opts.workspaceRoot, {
            turn: turnStart.turn,
            enabledSkills: runtimeContext?.skills ?? [],
            skillRoots: skillRootsFromOptions(opts),
            requestSkillOverlay: opts.requestSkillOverlay,
            replaceSkillOverlay: opts.replaceSkillOverlay,
            clearSkillOverlay: opts.clearSkillOverlay
          })
        ]
      },
      {
        model,
        convertToLlm: messages => messages.flatMap(message => (isLlmMessage(message) ? [message] : [])),
        getSteeringMessages: async () => steeringMessages(turnStart, opts.pollSteering?.() ?? []),
        toolExecution: 'parallel',
        maxTurns: opts.maxSteps ?? 8,
        nudgeOnEmptyAfterTools: true,
        metadata: {
          agent_uid: turnStart.turn.actor.agent_uid,
          conversation_id: turnStart.turn.actor.session_id,
          llm_turn_id: turnStart.turn.llm_turn_id,
          profile: credential.profile,
          provider_id: credential.provider_id,
          provider_source: credential.provider_source
        },
        headers: model.headers,
        providerOptions,
        maxTokens: model.maxTokens > 0 ? model.maxTokens : undefined,
        maxRetries: 2,
        maxRetryDelayMs: 2_000,
        timeoutMs: TEXT_TURN_TIMEOUT_MS
      },
      observeAgentEvent(telemetry),
      turnTimeout.signal
    )
    const latest = latestAssistantMessage(newMessages)
    if (latest?.stopReason === 'error' || latest?.stopReason === 'aborted') {
      throw new Error(
        latest.errorMessage ||
          (latest.stopReason === 'aborted' ? 'LLM provider call aborted' : 'LLM provider returned an error')
      )
    }
    const replyText = assistantText(latest)
    if (!replyText) {
      throw new Error(`LLM turn completed without visible assistant text: ${summarizeAgentMessages(newMessages)}`)
    }
    return finalProposalWithTelemetry(replyText, telemetry, replyAttachmentStore)
  } finally {
    turnTimeout.cleanup()
  }
}

async function runAmbientMayInterveneHandler(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<FinalProposalBody> {
  const lightCredential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: 'light',
    purpose: 'ai_turn'
  })

  if ('code' in lightCredential) {
    throw new Error(`credential rejected: ${lightCredential.code} ${lightCredential.message ?? ''}`.trim())
  }

  const lightModel = runtimeModelFromCredential(lightCredential)
  const agentProfile = opts.agentProfile ?? (await resolveAgentProfile(turnStart, opts))
  const runtimeContext = await resolveTurnRuntimeContext(turnStart, opts)
  const recognition = await runAmbientRecognizer({
    headers: lightModel.headers ?? {},
    model: lightModel,
    providerOptions: providerOptionsFromCredential(lightCredential, lightModel.provider),
    agentProfile,
    turnStart,
    runtimeContext,
    workspaceRoot: opts.workspaceRoot,
    timeoutMs: AMBIENT_RECOGNIZER_TIMEOUT_MS
  })

  if (!recognition.decision.intervene || !recognition.intervention) {
    return { messages: [], reply: null }
  }

  const interventionPrompt = renderMessageWithContext(
    userMessage(recognition.intervention.text),
    recognition.intervention.metadata
  )
  const replyProposal = await runTextTurnLoop(turnStart, {
    ...opts,
    agentProfile,
    runtimeContext,
    extraMessages: [...(opts.extraMessages ?? []), interventionPrompt]
  })
  const replyText = replyProposal.reply?.text ?? ''

  return {
    ...replyProposal,
    messages: [recognition.intervention.proposedMessage],
    reply: {
      text: replyText,
      content_json: [{ type: 'text', text: replyText }],
      ...(replyProposal.reply?.attachments?.length ? { attachments: replyProposal.reply.attachments } : {})
    }
  }
}

async function runCompressionTurn(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<FinalProposalBody> {
  const modelRef = turnStart.model_ref
  if (!modelRef) {
    throw new Error('Compression turn is missing a real model_ref')
  }

  const credential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: modelRef.profile,
    purpose: 'ai_turn'
  })

  if ('code' in credential) {
    throw new Error(`credential rejected: ${credential.code} ${credential.message ?? ''}`.trim())
  }

  assertCredentialMatchesTurn(modelRef, credential)

  const model = runtimeModelFromCredential(credential)
  const providerOptions = providerOptionsFromCredential(credential, model.provider)
  const telemetry = createTurnTelemetry(credential, model)
  const runtimeContext = await resolveTurnRuntimeContext(turnStart, opts)
  const conversation = conversationContextFromRuntimeContext(runtimeContext, model)
  const prompt = buildCompactionHistoryUserPrompt({
    conversationText: serializeConversationForCompression(conversation.messages),
    customInstructions: COMPACTION_FOCUS_INSTRUCTIONS,
    previousChatHistory: lastNonEmpty(conversation.previousChatHistorySummaries)
  })

  const turnTimeout = createCombinedAbortSignal(undefined, COMPRESSION_TURN_TIMEOUT_MS)
  try {
    const newMessages = await runAgentLoop(
      [userMessage(prompt)],
      {
        systemPrompt: SUMMARIZATION_SYSTEM_PROMPT,
        messages: [],
        tools: []
      },
      {
        model,
        convertToLlm: messages => messages.flatMap(message => (isLlmMessage(message) ? [message] : [])),
        maxTurns: 1,
        metadata: {
          agent_uid: turnStart.turn.actor.agent_uid,
          conversation_id: turnStart.turn.actor.session_id,
          llm_turn_id: turnStart.turn.llm_turn_id,
          profile: credential.profile,
          provider_id: credential.provider_id,
          provider_source: credential.provider_source,
          purpose: 'compression'
        },
        headers: model.headers,
        providerOptions,
        maxTokens: model.maxTokens > 0 ? model.maxTokens : undefined,
        maxRetries: 2,
        maxRetryDelayMs: 2_000,
        timeoutMs: COMPRESSION_TURN_TIMEOUT_MS
      },
      observeAgentEvent(telemetry),
      turnTimeout.signal
    )
    const latest = latestAssistantMessage(newMessages)
    if (latest?.stopReason === 'error' || latest?.stopReason === 'aborted') {
      throw new Error(
        latest.errorMessage ||
          (latest.stopReason === 'aborted' ? 'LLM provider call aborted' : 'LLM provider returned an error')
      )
    }

    const summaryText = stripCompactionScratch(assistantText(latest))
    if (!summaryText) {
      throw new Error(`Compression turn completed without summary text: ${summarizeAgentMessages(newMessages)}`)
    }

    return finalProposalWithTelemetry(summaryText, telemetry)
  } finally {
    turnTimeout.cleanup()
  }
}

async function resolveAgentProfile(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<AgentProfile> {
  if (!opts.requestAgentProfile) {
    return {
      request_id: '',
      agent_uid: turnStart.turn.actor.agent_uid,
      display_name: turnStart.turn.actor.agent_uid,
      role: undefined
    }
  }

  return await opts.requestAgentProfile({
    request_id: `agent-profile-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id
  })
}

async function resolveTurnRuntimeContext(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnRuntimeContext> {
  if (opts.runtimeContext) return opts.runtimeContext
  if (!opts.requestTurnContext) {
    throw new Error('turn runtime context RPC is required')
  }

  return await opts.requestTurnContext({
    request_id: `turn-context-${crypto.randomUUID()}`,
    turn: turnStart.turn
  })
}

function isAmbientMayInterveneTurn(turnStart: TurnStart): boolean {
  return turnStart.inputs.length > 0 && turnStart.inputs.every(input => input.type === 'im.message.may_intervene')
}

function isCompressionTurn(turnStart: TurnStart): boolean {
  return turnStart.inputs.length > 0 && turnStart.inputs.every(input => input.type === 'command.compress')
}

/**
 * Reads worker-process timing knobs once at module load. RuntimeFabric must not
 * leave provider calls unbounded: a hung LLM call should become a durable failed
 * turn, not an invisible in-flight worker task.
 */
function positiveIntegerEnv(name: string, fallback: number): number {
  const raw = process.env[name]
  if (!raw) return fallback

  const value = Number.parseInt(raw, 10)
  return Number.isFinite(value) && value > 0 ? value : fallback
}

function assertCredentialMatchesTurn(
  modelRef: NonNullable<TurnStart['model_ref']>,
  credential: LlmProviderCredentialResponse
): void {
  if (
    credential.profile !== modelRef.profile ||
    credential.provider_id !== modelRef.provider_id ||
    credential.model !== modelRef.model
  ) {
    throw new Error('credential response does not match turn model_ref')
  }
}

/**
 * Converts Ankole's provider-source vocabulary into a BullX `Model` plus the
 * concrete SDK model instance. Source names differ (`claude`/`gemini` in
 * Ankole, `anthropic`/`google` in the fork), but the model behavior stays in the
 * copied provider implementations.
 */
function runtimeModelFromCredential(credential: LlmProviderCredentialResponse): Model {
  const providerKind = providerKindFromSource(credential.provider_source)
  const catalogModel = getModel(providerKind, credential.model)
  if (!catalogModel) {
    throw new Error(`LLM model ${providerKind}/${credential.model} is not in the runtime catalog`)
  }
  const connection = credential.connection_options_json ?? {}
  const baseUrl = credential.base_url || stringArg(connection, 'base_url') || catalogModel.baseUrl
  const headers = runtimeHeaders(credential)
  const queryParams = stringRecord(recordArg(connection, 'query_params'))
  const sdkModel = createSdkModel({
    providerKind,
    credential,
    baseUrl,
    headers,
    queryParams
  })

  return {
    ...catalogModel,
    provider: providerKind,
    baseUrl,
    headers,
    sdkModel
  }
}

function createSdkModel(input: {
  providerKind: string
  credential: LlmProviderCredentialResponse
  baseUrl: string
  headers: Record<string, string>
  queryParams: Record<string, string>
}): LanguageModel {
  switch (input.providerKind) {
    case 'openai':
      return createOpenAI({
        apiKey: input.credential.credential,
        baseURL: input.baseUrl,
        headers: input.headers
      })(input.credential.model as never)
    case 'anthropic':
      return createAnthropic({
        ...(input.credential.credential_mode === 'auth_token'
          ? { authToken: input.credential.credential }
          : { apiKey: input.credential.credential }),
        baseURL: input.baseUrl,
        headers: input.headers
      })(input.credential.model as never)
    case 'google':
      return createGoogle({
        apiKey: input.credential.credential,
        baseURL: input.baseUrl,
        headers: input.headers
      })(input.credential.model as never)
    default:
      return createOpenAICompatible({
        name: input.providerKind,
        apiKey: input.credential.credential,
        baseURL: input.baseUrl,
        headers: input.headers,
        queryParams: input.queryParams,
        includeUsage: true,
        supportsStructuredOutputs: true
      })(input.credential.model)
  }
}

function providerKindFromSource(source: string): string {
  switch (source) {
    case 'claude':
      return 'anthropic'
    case 'gemini':
      return 'google'
    case 'openrouter':
    case 'openai':
    case 'openai-compatible':
    case 'xai':
    case 'groq':
    case 'cerebras':
    case 'deepseek':
    case 'moonshotai':
    case 'fireworks':
    case 'together':
      return source
    default:
      throw new Error(`unsupported LLM provider_source: ${source}`)
  }
}

function runtimeHeaders(credential: LlmProviderCredentialResponse): Record<string, string> {
  const headers = {
    ...stringRecord(recordArg(credential.connection_options_json, 'headers')),
    ...openAIAccountHeaders(credential.connection_options_json)
  }

  if (credential.provider_source === 'openrouter') {
    return {
      'HTTP-Referer': 'https://ankole.local',
      'X-OpenRouter-Title': 'Ankole Agent Computer',
      ...headers
    }
  }

  return headers
}

/**
 * Re-keys control-plane profile options into the AI SDK provider-options shape.
 *
 * Ankole validates flat per-source options on the model profile. The copied
 * BullX provider fork expects the AI SDK convention: `{ providerName: options }`.
 * Keeping the wrapping here preserves both boundaries and avoids teaching the
 * provider fork about control-plane storage details.
 */
function providerOptionsFromCredential(
  credential: LlmProviderCredentialResponse,
  providerKind: string
): ProviderOptions | undefined {
  const options = credential.provider_options_json
  if (!isRecord(options) || Object.keys(options).length === 0) return undefined

  if (isRecord(options[providerKind])) {
    return options as ProviderOptions
  }

  return {
    [providerKind]: options
  } as ProviderOptions
}

function conversationContextFromRuntimeContext(context: TurnRuntimeContext, model: Model): ConversationContext {
  const materializedInputIds = new Set<string>()
  const messages: AgentMessage[] = []
  const pendingUserEnvironmentInfoLines: string[] = []
  const previousChatHistorySummaries: string[] = []

  for (const row of context.conversation?.messages ?? []) {
    const metadata = isRecord(row.metadata) ? (row.metadata as JsonObject) : {}
    const actorInputId = deepString(metadata, ['actor_input_id'])
    if (actorInputId) materializedInputIds.add(actorInputId)

    const kind = typeof row.kind === 'string' ? row.kind : 'normal'
    const text = storedContentText(row.content)
    if (!text) continue

    if (kind === 'summary') {
      previousChatHistorySummaries.push(text)
      continue
    }
    if (kind === 'introspection' && row.role !== 'im_ambient') {
      pendingUserEnvironmentInfoLines.push(runtimeNoteEnvironmentInfoLine(text))
      continue
    }

    const message = storedConversationMessage(
      {
        role: row.role,
        kind,
        content: row.content,
        metadata
      },
      text,
      model
    )
    if (message) messages.push(message)
  }

  return { messages, materializedInputIds, pendingUserEnvironmentInfoLines, previousChatHistorySummaries }
}

function storedConversationMessage(line: JsonObject, text: string, model: Model): AgentMessage | undefined {
  const role = typeof line.role === 'string' ? line.role : 'user'
  if (role === 'assistant') {
    return assistantMessage(model, text)
  }
  if (role === 'im_ambient' && line.kind !== 'introspection') {
    return undefined
  }
  return renderMessageWithContext(userMessage(text), recordArg(line, 'metadata') ?? {})
}

/**
 * Filters inputs that were already materialized by the control plane. Ambient
 * intervention inputs are synthetic wakeups whose user-facing text already
 * lives in the persisted introspection message, so re-rendering their payload
 * would duplicate the same trigger.
 */
function inputAlreadyMaterialized(input: ActorInputEnvelope, conversation: ConversationContext): boolean {
  return (
    conversation.materializedInputIds.has(input.actor_input_id) ||
    Boolean(deepString(input.payload_json, ['data', 'internal', 'trigger_message_id']))
  )
}

function attachPendingEnvironmentInfoToUserMessage(
  messages: AgentMessage[],
  prompts: Message[],
  lines: string[]
): { messages: AgentMessage[]; prompts: Message[] } {
  const environmentInfoLines = lines.filter(line => line.trim().length > 0)
  if (environmentInfoLines.length === 0) return { messages, prompts }

  const promptIndex = prompts.findIndex(message => message.role === 'user')
  if (promptIndex >= 0) {
    const nextPrompts = [...prompts]
    nextPrompts[promptIndex] = prependEnvironmentInfoLinesToUserMessage(
      nextPrompts[promptIndex]!,
      environmentInfoLines
    ) as Message
    return { messages, prompts: nextPrompts }
  }

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role !== 'user') continue
    const nextMessages = [...messages]
    nextMessages[index] = prependEnvironmentInfoLinesToUserMessage(nextMessages[index]!, environmentInfoLines)
    return { messages: nextMessages, prompts }
  }

  return {
    messages,
    prompts: [prependEnvironmentInfoLinesToUserMessage(userMessage(''), environmentInfoLines) as Message, ...prompts]
  }
}

function attachPreviousChatHistoryToUserMessage(
  messages: AgentMessage[],
  prompts: Message[],
  history: string | undefined
): { messages: AgentMessage[]; prompts: Message[] } {
  const previousHistory = history?.trim()
  if (!previousHistory) return { messages, prompts }

  const promptIndex = prompts.findIndex(message => message.role === 'user')
  if (promptIndex >= 0) {
    const nextPrompts = [...prompts]
    nextPrompts[promptIndex] = prependPreviousChatHistoryToUserMessage(
      nextPrompts[promptIndex]!,
      previousHistory
    ) as Message
    return { messages, prompts: nextPrompts }
  }

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role !== 'user') continue
    const nextMessages = [...messages]
    nextMessages[index] = prependPreviousChatHistoryToUserMessage(nextMessages[index]!, previousHistory)
    return { messages: nextMessages, prompts }
  }

  return {
    messages,
    prompts: [prependPreviousChatHistoryToUserMessage(userMessage(''), previousHistory) as Message, ...prompts]
  }
}

function runtimeNoteEnvironmentInfoLine(text: string): string {
  return `runtime_note: ${text.replace(/\s+/g, ' ').trim()}`
}

function currentChannelFromTurnStart(turnStart: TurnStart): CurrentChannelContext | undefined {
  for (const input of turnStart.inputs) {
    const channel = objectPath(input.payload_json, ['data', 'channel'])
    const kind = channelKind(stringArg(channel, 'kind'))
    const id = stringArg(channel, 'id') ?? deepString(input.payload_json, ['data', 'entry', 'signal_channel_id'])
    if (!kind && !id) continue

    const platform = sourcePlatform(input.payload_json)
    return {
      ...(stringArg(channel, 'name') || stringArg(channel, 'title')
        ? { name: stringArg(channel, 'name') ?? stringArg(channel, 'title') }
        : {}),
      ...(id ? { id } : {}),
      ...(platform ? { platform } : {}),
      ...(deepString(input.payload_json, ['data', 'session', 'binding_name'])
        ? {
            bindingName: deepString(input.payload_json, ['data', 'session', 'binding_name'])
          }
        : {}),
      kind: kind ?? 'external_room'
    }
  }
}

function channelKind(kind: string | undefined): CurrentChannelContext['kind'] | undefined {
  switch (kind) {
    case 'im_dm':
      return 'external_dm'
    case 'im_group':
      return 'external_group'
    case undefined:
      return undefined
    default:
      return 'external_room'
  }
}

function sourcePlatform(payload: JsonObject | undefined): string | undefined {
  const source = deepString(payload, ['source'])
  if (!source?.startsWith('signal://')) return undefined
  const withoutScheme = source.slice('signal://'.length)
  const separatorIndex = withoutScheme.indexOf('/')
  return separatorIndex >= 0 ? withoutScheme.slice(0, separatorIndex) : withoutScheme
}

function steeringMessages(turnStart: TurnStart, updates: TurnSteerUpdate[]): AgentMessage[] {
  const applicable = updates.filter(update => {
    return (
      update.turn.actor.agent_uid === turnStart.turn.actor.agent_uid &&
      update.turn.actor.session_id === turnStart.turn.actor.session_id &&
      update.turn.activation_uid === turnStart.turn.activation_uid &&
      update.turn.actor_epoch === turnStart.turn.actor_epoch &&
      update.turn.llm_turn_id === turnStart.turn.llm_turn_id &&
      update.turn.revision > turnStart.turn.revision
    )
  })

  if (applicable.length === 0) return []

  const messages: AgentMessage[] = [
    userMessage(
      'Runtime note:\nThe user sent /steer while this turn was running. Do not continue the previous tool plan by inertia; continue from the latest steering instructions below.'
    )
  ]

  for (const update of applicable) {
    turnStart.turn.revision = update.turn.revision
    for (const input of update.inputs) {
      messages.push(userMessage(`Steering instruction:\n${inputText(input.payload_json, input.type)}`))
    }
  }

  return messages
}

function userMessage(text: string): Message {
  return {
    role: 'user',
    content: [{ type: 'text', text }],
    timestamp: Date.now()
  }
}

function assistantMessage(model: Model, text: string): AssistantMessage {
  return {
    role: 'assistant',
    content: [{ type: 'text', text }],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    },
    stopReason: 'stop',
    timestamp: Date.now()
  }
}

function isLlmMessage(message: AgentMessage): message is Message {
  return isRecord(message) && (message.role === 'user' || message.role === 'assistant' || message.role === 'toolResult')
}

function latestAssistantMessage(messages: AgentMessage[]): AssistantMessage | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]
    if (isRecord(message) && message.role === 'assistant') {
      return message as AssistantMessage
    }
  }
}

function assistantText(message: AssistantMessage | undefined): string {
  if (!message) return ''
  return message.content
    .map(block => (block.type === 'text' ? block.text : undefined))
    .filter((text): text is string => typeof text === 'string')
    .join('\n')
    .trim()
}

function stripCompactionScratch(summary: string): string {
  return summary.replace(/<analysis>[\s\S]*?<\/analysis>/gi, '').trim()
}

function serializeConversationForCompression(messages: AgentMessage[]): string {
  const parts: string[] = []

  for (const message of messages) {
    if (!isLlmMessage(message)) continue

    if (message.role === 'user') {
      const content = messageContentText(message.content)
      if (content) parts.push(`[User]: ${content}`)
      continue
    }

    if (message.role === 'assistant') {
      const textParts: string[] = []
      const thinkingParts: string[] = []
      const toolCalls: string[] = []

      for (const block of message.content) {
        if (block.type === 'text') {
          textParts.push(block.text)
        } else if (block.type === 'thinking') {
          thinkingParts.push(block.thinking)
        } else if (block.type === 'toolCall') {
          const args = Object.entries(block.arguments as Record<string, unknown>)
            .map(([key, value]) => `${key}=${safeJsonStringify(value)}`)
            .join(', ')
          toolCalls.push(`${block.name}(${args})`)
        }
      }

      if (thinkingParts.length > 0) parts.push(`[Assistant thinking]: ${thinkingParts.join('\n')}`)
      if (textParts.length > 0) parts.push(`[Assistant]: ${textParts.join('\n')}`)
      if (toolCalls.length > 0) parts.push(`[Assistant tool calls]: ${toolCalls.join('; ')}`)
      continue
    }

    if (message.role === 'toolResult') {
      const content = messageContentText(message.content)
      if (content) parts.push(`[Tool result]: ${truncateForSummary(content, TOOL_RESULT_MAX_CHARS)}`)
    }
  }

  return parts.join('\n\n')
}

function messageContentText(content: Message['content']): string {
  if (typeof content === 'string') return content
  return content
    .map(block => (block.type === 'text' ? block.text : undefined))
    .filter((text): text is string => typeof text === 'string')
    .join('')
}

function truncateForSummary(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  const truncatedChars = text.length - maxChars
  return `${text.slice(0, maxChars)}\n\n[... ${truncatedChars} more characters truncated]`
}

function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function lastNonEmpty(values: string[]): string | undefined {
  for (let index = values.length - 1; index >= 0; index -= 1) {
    const value = values[index]?.trim()
    if (value) return value
  }
}

function createTurnTelemetry(credential: LlmProviderCredentialResponse, model: Model): TurnTelemetry {
  return {
    providerMetadata: {
      provider_id: credential.provider_id,
      provider_source: credential.provider_source,
      model: credential.model,
      runtime_provider: model.provider
    },
    toolResults: []
  }
}

function observeAgentEvent(telemetry: TurnTelemetry): (event: AgentEvent) => void {
  return event => {
    switch (event.type) {
      case 'turn_end':
        if (isAssistantMessage(event.message)) {
          applyAssistantTelemetry(telemetry, event.message)
        }
        break

      case 'tool_execution_end':
        telemetry.toolResults.push({
          tool_call_id: event.toolCallId,
          tool_name: event.toolName,
          args: jsonValue(event.args),
          result: jsonValue(event.result),
          is_error: event.isError
        })
        break
    }
  }
}

function applyAssistantTelemetry(telemetry: TurnTelemetry, message: AssistantMessage): void {
  telemetry.usage = jsonObject(message.usage)
  telemetry.stopReason = message.stopReason
  telemetry.providerMetadata = {
    ...telemetry.providerMetadata,
    ...(message.responseId ? { response_id: message.responseId } : {}),
    ...(message.responseModel ? { response_model: message.responseModel } : {})
  }
}

function finalProposalWithTelemetry(
  text: string,
  telemetry: TurnTelemetry,
  replyAttachmentStore?: ReplyAttachmentStore
): FinalProposalBody {
  const attachments = replyAttachmentStore?.attachments ?? []

  return {
    ...visibleReplyProposal(text),
    ...(attachments.length > 0
      ? {
          reply: {
            text,
            content_json: [{ type: 'text', text }],
            attachments
          }
        }
      : {}),
    ...(telemetry.usage ? { usage_json: telemetry.usage } : {}),
    provider_metadata_json: telemetry.providerMetadata,
    ...(telemetry.stopReason ? { stop_reason: telemetry.stopReason } : {}),
    tool_results_json: telemetry.toolResults
  }
}

function isAssistantMessage(message: AgentMessage): message is AssistantMessage {
  return isRecord(message) && message.role === 'assistant'
}

function jsonObject(value: unknown): JsonObject {
  const normalized = jsonValue(value)
  return isRecord(normalized) ? normalized : {}
}

function jsonValue(value: unknown): unknown {
  if (value === null || value === undefined) return null
  if (Array.isArray(value)) return value.map(jsonValue)
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([key, value]) => [key, jsonValue(value)]))
  return String(value)
}

function summarizeAgentMessages(messages: AgentMessage[]): string {
  return messages
    .map(message => {
      if (!isRecord(message)) return 'unknown'
      if (message.role === 'assistant') {
        const blocks = Array.isArray(message.content)
          ? message.content
              .map(block => {
                if (!isRecord(block)) return 'block'
                if (block.type === 'text') return `text:${String(block.text ?? '').slice(0, 80)}`
                if (block.type === 'toolCall') return `toolCall:${String(block.name ?? '')}`
                return String(block.type ?? 'block')
              })
              .join(',')
          : 'no-content'
        return `assistant(${String(message.stopReason ?? 'unknown')} ${blocks})`
      }
      if (message.role === 'toolResult') {
        return `toolResult(${String(message.toolName ?? 'unknown')} error=${String(message.isError ?? false)})`
      }
      if (message.role === 'user') {
        return 'user'
      }
      return String(message.role ?? 'unknown')
    })
    .join(' -> ')
}

function storedContentText(content: unknown): string {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .map(part => {
        if (typeof part === 'string') return part
        if (isRecord(part) && typeof part.text === 'string') return part.text
        return undefined
      })
      .filter((part): part is string => part !== undefined)
      .join('\n')
  }
  return ''
}

function inputText(payload: JsonObject | undefined, fallbackType: string): string {
  const text = fallbackType.startsWith('command.')
    ? deepString(payload, ['data', 'command', 'argsText']) ||
      deepString(payload, ['data', 'entry', 'text']) ||
      deepString(payload, ['data', 'internal', 'text'])
    : deepString(payload, ['data', 'entry', 'text']) ||
      deepString(payload, ['data', 'command', 'argsText']) ||
      deepString(payload, ['data', 'internal', 'text'])

  const attachments = attachmentText(payload)
  const base = text || `Handle actor input of type ${fallbackType}.`
  return attachments ? `${base}\n\nAttachments:\n${attachments}` : base
}

function deepString(value: unknown, path: string[]): string | undefined {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return undefined
    current = current[key]
  }
  return typeof current === 'string' ? current : undefined
}

function attachmentText(payload: JsonObject | undefined): string | undefined {
  const attachments = arrayPath(payload, ['data', 'entry', 'attachments'])
  if (attachments.length === 0) return undefined

  return (
    attachments
      .map((attachment, index) => attachmentLine(attachment, index))
      .filter((line): line is string => line !== undefined)
      .join('\n') || undefined
  )
}

function attachmentLine(value: unknown, index: number): string | undefined {
  if (!isRecord(value)) return undefined

  const name = firstString(value, ['name', 'filename', 'file_name', 'title'])
  const type = firstString(value, ['resource_type', 'mime_type', 'content_type', 'download_type'])
  const path = firstString(value, ['agent_computer_path', 'file_path', 'path'])
  const reference = firstString(value, ['provider_ref', 'provider_file_id', 'provider_uri', 'blob_ref', 'storage_ref'])
  const size = firstNumber(value, ['size', 'size_bytes', 'bytes'])
  const details: string[] = []

  if (type) details.push(`type=${type}`)
  if (size !== undefined) details.push(`size=${size}`)
  if (path) {
    details.push(`path=${path}`)
  } else if (reference) {
    details.push(`provider_ref=${reference}`)
    details.push('not_materialized_in_workspace=true')
  }

  if (details.length === 0 && !name) return undefined
  return `- ${name || `attachment ${index + 1}`}: ${details.join(', ')}`
}

function arrayPath(value: unknown, path: string[]): unknown[] {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return []
    current = current[key]
  }
  return Array.isArray(current) ? current : []
}

function firstString(record: JsonObject, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'string' && value.length > 0) return value
  }
}

function firstNumber(record: JsonObject, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'number' && Number.isFinite(value)) return value
  }
}

function openAIAccountHeaders(options: JsonObject | undefined): Record<string, string> {
  const headers: Record<string, string> = {}
  const organization = stringArg(options ?? {}, 'organization')
  const project = stringArg(options ?? {}, 'project')
  if (organization) headers['OpenAI-Organization'] = organization
  if (project) headers['OpenAI-Project'] = project
  return headers
}

function stringRecord(value: JsonObject | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, nested] of Object.entries(value ?? {})) {
    if (typeof nested === 'string') out[key] = nested
  }
  return out
}

function recordArg(args: JsonObject | undefined, key: string): JsonObject | undefined {
  const value = args?.[key]
  return isRecord(value) ? value : undefined
}

function stringArg(args: JsonObject | undefined, key: string): string | undefined {
  const value = args?.[key]
  return typeof value === 'string' ? value : undefined
}

function objectPath(source: unknown, path: string[]): JsonObject {
  const value = path.reduce<unknown>((current, key) => (isRecord(current) ? current[key] : undefined), source)
  return isRecord(value) ? value : {}
}

function isRecord(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
