import { existsSync, readFileSync } from 'node:fs'
import { normalize, resolve } from 'node:path'
import type {
  ActorInputEnvelope,
  JsonObject,
  LlmProviderCredentialRejected,
  LlmProviderCredentialRequest,
  LlmProviderCredentialResponse,
  TurnStart,
  TurnSteerUpdate
} from '../actor_bus'
import { runAgentLoop, type AgentEvent, type AgentMessage } from '../core'
import { createAnthropic } from '../llm/providers/anthropic'
import { createGoogle } from '../llm/providers/google'
import { createOpenAI } from '../llm/providers/openai'
import { createOpenAICompatible } from '../llm/providers/openai-compatible'
import { getModel } from '../llm/catalog'
import type { AssistantMessage, Message, Model } from '../llm/bullx'
import type { ProviderOptions } from '../llm/provider-utils'
import type { LanguageModel } from '../llm/types'
import { buildAgentSystemPrompt, type CurrentChannelContext } from '../prompts/system_prompt'
import { visibleReplyProposal, type FinalProposalBody } from '../ping_pong_handler'
import { createComputerTools } from '../tools/computer'
import { createSkillTools } from '../tools/library/skill-tools'
import { createTodoTool, TodoStore } from '../tools/todo-tool'
import { runAmbientRecognizer } from './ambient_recognizer'
import { renderMessageWithContext } from './message_context'

export type CredentialRequester = (
  request: LlmProviderCredentialRequest
) => Promise<LlmProviderCredentialResponse | LlmProviderCredentialRejected>

export type TextTurnLoopOptions = {
  workspaceRoot: string
  requestCredential: CredentialRequester
  pollSteering?: () => TurnSteerUpdate[]
  maxSteps?: number
  extraMessages?: AgentMessage[]
}

type ConversationContext = {
  messages: AgentMessage[]
  materializedInputIds: Set<string>
  systemNotes: string[]
}

/**
 * Dispatches one worker turn by ActorInput type. These are internal Agent
 * Computer handlers: ZMQ delivered only the event batch, while recognizers and
 * follow-up generation stay inside the local AI SDK runtime.
 */
export async function runLlmTurnHandlers(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<FinalProposalBody> {
  if (isAmbientMayInterveneTurn(turnStart)) {
    return runAmbientMayInterveneHandler(turnStart, opts)
  }

  return visibleReplyProposal(await runTextTurnLoop(turnStart, opts))
}

/**
 * Runs one Ankole text turn inside Agent Computer.
 *
 * The control plane delivers actor inputs and an opaque `model_ref`; the worker
 * resolves credentials over the parent protocol, builds the concrete BullX AI SDK
 * model locally, and lets BullX's reusable agent loop own tool-call/result turns.
 * This keeps credentials memory-only and keeps provider-specific behavior inside
 * the copied BullX LLM fork instead of hand-writing per-provider HTTP payloads.
 */
export async function runTextTurnLoop(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<string> {
  const modelRef = turnStart.model_ref
  if (!modelRef || modelRef.provider_id === 'ankole-placeholder') {
    return 'PONG'
  }

  const credential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
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

  const conversation = loadConversationContext(opts.workspaceRoot, turnStart, model)
  const todoStore = new TodoStore()
  const prompts = turnStart.inputs
    .filter(input => !inputAlreadyMaterialized(input, conversation))
    .map(input => userMessage(inputText(input.payload_json, input.type)))

  const systemPrompt = [
    buildAgentSystemPrompt({
      workspaceRoot: opts.workspaceRoot,
      turnStart,
      currentChannel: currentChannelFromTurnStart(turnStart)
    }),
    ...conversation.systemNotes
  ]
    .filter(note => note.trim().length > 0)
    .join('\n\n')

  const newMessages = await runAgentLoop(
    prompts,
    {
      systemPrompt,
      messages: [...conversation.messages, ...(opts.extraMessages ?? [])],
      tools: [
        createTodoTool(todoStore),
        ...createComputerTools({
          agentUid: turnStart.turn.actor.agent_uid,
          conversationId: turnStart.turn.actor.session_id,
          workspaceRoot: opts.workspaceRoot
        }),
        ...createSkillTools(opts.workspaceRoot)
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
      maxRetryDelayMs: 2_000
    },
    observeAgentEvent
  )

  const latest = latestAssistantMessage(newMessages)
  if (latest?.stopReason === 'error') {
    throw new Error(latest.errorMessage || 'LLM provider returned an error')
  }
  const replyText = assistantText(latest)
  if (!replyText) {
    throw new Error(`LLM turn completed without visible assistant text: ${summarizeAgentMessages(newMessages)}`)
  }
  return replyText
}

async function runAmbientMayInterveneHandler(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<FinalProposalBody> {
  const lightCredential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: 'light',
    purpose: 'ai_turn'
  })

  if ('code' in lightCredential) {
    throw new Error(`credential rejected: ${lightCredential.code} ${lightCredential.message ?? ''}`.trim())
  }

  const lightModel = runtimeModelFromCredential(lightCredential)
  const recognition = await runAmbientRecognizer({
    headers: lightModel.headers ?? {},
    model: lightModel,
    providerOptions: providerOptionsFromCredential(lightCredential, lightModel.provider),
    turnStart,
    workspaceRoot: opts.workspaceRoot
  })

  if (!recognition.decision.intervene || !recognition.intervention) {
    return { messages: [], reply: null }
  }

  const interventionPrompt = renderMessageWithContext(
    userMessage(recognition.intervention.text),
    recognition.intervention.metadata
  )
  const replyText = await runTextTurnLoop(turnStart, {
    ...opts,
    extraMessages: [...(opts.extraMessages ?? []), interventionPrompt]
  })

  return {
    messages: [recognition.intervention.proposedMessage],
    reply: {
      text: replyText,
      content_json: [{ type: 'text', text: replyText }]
    }
  }
}

function isAmbientMayInterveneTurn(turnStart: TurnStart): boolean {
  return turnStart.inputs.length > 0 && turnStart.inputs.every(input => input.type === 'im.message.may_intervene')
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
  const catalogModel = getModel(providerKind, credential.model) ?? fallbackModel(providerKind, credential.model)
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
      return source
    default:
      return 'openai-compatible'
  }
}

function fallbackModel(providerKind: string, modelId: string): Model {
  return {
    id: modelId,
    name: modelId,
    api:
      providerKind === 'anthropic'
        ? 'anthropic-messages'
        : providerKind === 'google'
          ? 'google-generative-ai'
          : 'openai-completions',
    provider: providerKind,
    baseUrl: '',
    reasoning: true,
    input: ['text', 'image'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000,
    maxTokens: 8192
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

function loadConversationContext(workspaceRoot: string, turnStart: TurnStart, model: Model): ConversationContext {
  const path = safePath(
    workspaceRoot,
    `/workspace/actors/${encodeURIComponent(turnStart.turn.actor.agent_uid)}/${encodeURIComponent(
      turnStart.turn.actor.session_id
    )}/conversation/messages.jsonl`
  )
  if (!existsSync(path)) {
    return { messages: [], materializedInputIds: new Set(), systemNotes: [] }
  }

  const materializedInputIds = new Set<string>()
  const messages: AgentMessage[] = []
  const systemNotes: string[] = []

  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const parsed = parseConversationLine(line)
    if (!parsed) continue

    const actorInputId = deepString(parsed, ['metadata', 'actor_input_id'])
    if (actorInputId) materializedInputIds.add(actorInputId)

    const kind = typeof parsed.kind === 'string' ? parsed.kind : 'normal'
    const text = storedContentText(parsed.content)
    if (!text) continue

    if (kind === 'summary') {
      systemNotes.push(`Conversation summary checkpoint:\n${text}`)
      continue
    }
    if (kind === 'introspection' && parsed.role !== 'im_ambient') {
      systemNotes.push(`Runtime note:\n${text}`)
      continue
    }

    const message = storedConversationMessage(parsed, text, model)
    if (message) messages.push(message)
  }

  return { messages, materializedInputIds, systemNotes }
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
        ? { bindingName: deepString(input.payload_json, ['data', 'session', 'binding_name']) }
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

function observeAgentEvent(_event: AgentEvent): void {}

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

function parseConversationLine(line: string): JsonObject | undefined {
  const trimmed = line.trim()
  if (!trimmed) return undefined
  try {
    const parsed = JSON.parse(trimmed)
    return isRecord(parsed) ? parsed : undefined
  } catch {
    return undefined
  }
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
  if (fallbackType.startsWith('command.')) {
    return (
      deepString(payload, ['data', 'command', 'argsText']) ||
      deepString(payload, ['data', 'entry', 'text']) ||
      deepString(payload, ['data', 'internal', 'text']) ||
      `Handle actor input of type ${fallbackType}.`
    )
  }

  return (
    deepString(payload, ['data', 'entry', 'text']) ||
    deepString(payload, ['data', 'command', 'argsText']) ||
    deepString(payload, ['data', 'internal', 'text']) ||
    `Handle actor input of type ${fallbackType}.`
  )
}

function deepString(value: unknown, path: string[]): string | undefined {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return undefined
    current = current[key]
  }
  return typeof current === 'string' ? current : undefined
}

function safePath(workspaceRoot: string, path: string): string {
  const normalized = normalize(path)
  const relative = normalized.startsWith('/workspace')
    ? normalized.slice('/workspace'.length)
    : normalized.startsWith('/')
      ? normalized
      : `/${normalized}`
  const resolved = resolve(workspaceRoot, `.${relative}`)
  const root = resolve(workspaceRoot)

  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('path escapes workspace root')
  }

  return resolved
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
