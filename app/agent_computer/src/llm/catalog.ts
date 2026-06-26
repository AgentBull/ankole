import { createAmazonBedrock } from './providers/amazon-bedrock'
import { createAnthropic } from './providers/anthropic'
import { createGoogle } from './providers/google'
import { createGoogleVertex } from './providers/google-vertex'
import { createOpenAI } from './providers/openai'
import { createOpenAICompatible } from './providers/openai-compatible'
import type { LanguageModel } from './types'
import type { Api, Model } from './bullx'

// Static catalog of the LLM providers/models Ankole ships with, plus the resolution helpers
// the control plane uses to turn a (provider, modelId) pair from DB config into a callable
// Model. Two provider classes live here: "first-class" providers with a fixed model list and
// their own AI SDK adapter, and "compatible" (OpenAI-compatible) providers where an operator
// may type ANY model id — for those, unknown ids are resolved to a synthetic Model.

/** Provider kinds Ankole knows how to build an AI SDK adapter for. The string is what's stored in installation config. */
export type LlmProviderKind =
  | 'openai'
  | 'anthropic'
  | 'google'
  | 'google-vertex'
  | 'amazon-bedrock'
  | 'openai-compatible'
  | 'openrouter'
  | 'xai'
  | 'groq'
  | 'cerebras'
  | 'deepseek'
  | 'moonshotai'
  | 'fireworks'
  | 'together'

/** One row in the static catalog. `compatible: true` marks an OpenAI-compatible provider that accepts arbitrary model ids. */
export interface LlmProviderCatalogEntry {
  id: string
  name: string
  baseUrl: string
  api: Api
  models: Model[]
  compatible?: boolean
}

/** Everything createLanguageModel needs from resolved DB config; `baseUrl` null/absent falls back to the model's default. */
export interface CreateLanguageModelInput {
  llmProvider: string
  model: Model
  apiKey: string
  baseUrl?: string | null
  headers?: Record<string, string>
  providerOptions?: Record<string, unknown>
}

// Default pricing for catalog models is ZERO across all buckets. Real per-token prices are
// expected to be supplied out-of-band (e.g. from operator config), so calculateCost on a
// raw catalog model reports 0 cost rather than a stale hardcoded number that would drift.
const zeroCost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }

// The shipped provider list. `model(...)` args after the names are: reasoning?, contextWindow,
// maxTokens — see the `model` factory below. Compatible providers may ship a seed model list
// (e.g. OpenRouter) or none at all (the operator enters ids by hand).
const catalog: LlmProviderCatalogEntry[] = [
  provider('openai', 'OpenAI', 'https://api.openai.com/v1', 'openai-responses', [
    model('gpt-5', 'GPT-5', 'openai', 'openai-responses', true, 400000, 128000),
    model('gpt-5-mini', 'GPT-5 mini', 'openai', 'openai-responses', true, 400000, 128000),
    model('gpt-4.1', 'GPT-4.1', 'openai', 'openai-responses', false, 1047576, 32768),
    model('gpt-4.1-mini', 'GPT-4.1 mini', 'openai', 'openai-responses', false, 1047576, 32768)
  ]),
  provider('anthropic', 'Anthropic', 'https://api.anthropic.com/v1', 'anthropic-messages', [
    model('claude-sonnet-4-5', 'Claude Sonnet 4.5', 'anthropic', 'anthropic-messages', true, 200000, 64000),
    model('claude-haiku-4-5', 'Claude Haiku 4.5', 'anthropic', 'anthropic-messages', true, 200000, 64000),
    model('claude-opus-4-1', 'Claude Opus 4.1', 'anthropic', 'anthropic-messages', true, 200000, 32000)
  ]),
  provider('google', 'Google Gemini', 'https://generativelanguage.googleapis.com/v1beta', 'google-generative-ai', [
    model('gemini-3-pro-preview', 'Gemini 3 Pro Preview', 'google', 'google-generative-ai', true, 1048576, 65536),
    model('gemini-2.5-pro', 'Gemini 2.5 Pro', 'google', 'google-generative-ai', true, 1048576, 65536),
    model('gemini-2.5-flash', 'Gemini 2.5 Flash', 'google', 'google-generative-ai', true, 1048576, 65536)
  ]),
  provider('google-vertex', 'Google Vertex AI', 'https://aiplatform.googleapis.com', 'google-vertex', [
    model('gemini-2.5-pro', 'Gemini 2.5 Pro', 'google-vertex', 'google-vertex', true, 1048576, 65536),
    model('gemini-2.5-flash', 'Gemini 2.5 Flash', 'google-vertex', 'google-vertex', true, 1048576, 65536)
  ]),
  provider(
    'amazon-bedrock',
    'Amazon Bedrock',
    'https://bedrock-runtime.us-east-1.amazonaws.com',
    'bedrock-converse-stream',
    [
      model(
        'anthropic.claude-3-5-sonnet-20241022-v2:0',
        'Claude 3.5 Sonnet',
        'amazon-bedrock',
        'bedrock-converse-stream',
        true,
        200000,
        8192
      )
    ]
  ),
  compatibleProvider('openai-compatible', 'OpenAI Compatible', 'https://api.openai.com/v1'),
  compatibleProvider('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1', [
    model('openai/gpt-5', 'OpenAI GPT-5', 'openrouter', 'openai-completions', true, 400000, 128000),
    model('anthropic/claude-sonnet-4.5', 'Claude Sonnet 4.5', 'openrouter', 'openai-completions', true, 200000, 64000)
  ]),
  compatibleProvider('xai', 'xAI', 'https://api.x.ai/v1', [
    model('grok-4', 'Grok 4', 'xai', 'openai-completions', true, 256000, 32768)
  ]),
  compatibleProvider('groq', 'Groq', 'https://api.groq.com/openai/v1'),
  compatibleProvider('cerebras', 'Cerebras', 'https://api.cerebras.ai/v1'),
  compatibleProvider('deepseek', 'DeepSeek', 'https://api.deepseek.com'),
  compatibleProvider('moonshotai', 'Moonshot AI', 'https://api.moonshot.ai/v1'),
  compatibleProvider('fireworks', 'Fireworks', 'https://api.fireworks.ai/inference/v1'),
  compatibleProvider('together', 'Together AI', 'https://api.together.xyz/v1')
]

/** Lists provider kinds that setup/console can offer before any tenant-specific provider row exists. */
export function getProviders(): string[] {
  return catalog.map(entry => entry.id)
}

/** Returns cloned catalog models so callers can safely attach runtime provider fields. */
export function getModels(llmProvider: string): Model[] {
  return getProviderEntry(llmProvider)?.models.map(cloneModel) ?? []
}

/**
 * Resolves a (provider, modelId) pair to a Model. If the id is in the catalog, returns a clone
 * of that entry. If not, falls back to a synthetic model — this is how compatible providers
 * support model ids Ankole has never heard of. Returns undefined only when the PROVIDER is
 * unknown; an unknown model under a known provider always resolves (via the synthetic fallback).
 */
export function getModel(llmProvider: string, modelId: string): Model | undefined {
  const entry = getProviderEntry(llmProvider)
  if (!entry) return undefined
  const found = entry.models.find(item => item.id === modelId)
  return found ? cloneModel(found) : syntheticModel(entry, modelId)
}

/** Looks up one provider catalog entry by the stable provider kind stored in config. */
export function getProviderEntry(llmProvider: string): LlmProviderCatalogEntry | undefined {
  return catalog.find(entry => entry.id === llmProvider)
}

/**
 * Instantiates the concrete AI SDK LanguageModel for a resolved provider/model. The result is
 * what gets attached to Model.sdkModel so generate/stream can actually call out. First-class
 * providers each get their dedicated adapter; every other provider id falls through to the
 * OpenAI-compatible adapter (the `default` case), which is why new compatible providers need
 * no code change here beyond a catalog entry.
 */
export function createLanguageModel(input: CreateLanguageModelInput): LanguageModel {
  // Operator-provided base URL wins; otherwise use the model's catalog default endpoint.
  const baseUrl = input.baseUrl ?? input.model.baseUrl
  const headers = input.headers
  const providerOptions = input.providerOptions ?? {}
  switch (input.llmProvider) {
    case 'openai':
      return createOpenAI({ apiKey: input.apiKey, baseURL: baseUrl, headers })(input.model.id as never)
    case 'anthropic':
      return createAnthropic({ apiKey: input.apiKey, baseURL: baseUrl, headers })(input.model.id as never)
    case 'google':
      return createGoogle({ apiKey: input.apiKey, baseURL: baseUrl, headers })(input.model.id as never)
    case 'google-vertex':
      return createGoogleVertex({
        apiKey: input.apiKey,
        baseURL: baseUrl,
        headers,
        ...(providerOptions as Record<string, never>)
      })(input.model.id as never)
    case 'amazon-bedrock':
      return createAmazonBedrock({
        apiKey: input.apiKey,
        baseURL: baseUrl,
        headers,
        ...(providerOptions as Record<string, never>)
      })(input.model.id as never)
    default:
      // All compatible providers (openrouter, xai, groq, deepseek, custom, …) share this path.
      // includeUsage asks the endpoint to return token usage so cost accounting works;
      // supportsStructuredOutputs assumes JSON-schema response support (most OpenAI clones have it).
      return createOpenAICompatible({
        name: input.llmProvider,
        apiKey: input.apiKey,
        baseURL: baseUrl,
        headers,
        includeUsage: true,
        supportsStructuredOutputs: true
      })(input.model.id)
  }
}

/** Builds a first-class provider entry and stamps its default base URL onto every bundled model. */
function provider(id: string, name: string, baseUrl: string, api: Api, models: Model[]): LlmProviderCatalogEntry {
  // `item.baseUrl || baseUrl`: model() leaves baseUrl '' so each model inherits the provider's
  // endpoint here, while still allowing a per-model override to win if one is ever set.
  return { id, name, baseUrl, api, models: models.map(item => ({ ...item, baseUrl: item.baseUrl || baseUrl })) }
}

/** Builds an OpenAI-compatible provider whose model list may be empty because operators can enter custom ids. */
function compatibleProvider(id: string, name: string, baseUrl: string, models: Model[] = []): LlmProviderCatalogEntry {
  return {
    id,
    name,
    baseUrl,
    // Compatible providers always speak the OpenAI completions dialect regardless of vendor.
    api: 'openai-completions',
    models: models.map(item => ({ ...item, baseUrl: item.baseUrl || baseUrl })),
    compatible: true
  }
}

/**
 * Factory for a catalog model. baseUrl is intentionally '' so the provider/compatibleProvider
 * wrappers fill it in; cost defaults to zero (see zeroCost). The two numbers are contextWindow
 * (total prompt budget, feeds isContextOverflow) and maxTokens (output cap). `input` is fixed to
 * text+image for every catalog model.
 */
function model(
  id: string,
  name: string,
  provider: string,
  api: Api,
  reasoning: boolean,
  contextWindow: number,
  maxTokens: number
): Model {
  return {
    id,
    name,
    api,
    provider,
    baseUrl: '',
    reasoning,
    input: ['text', 'image'],
    cost: zeroCost,
    contextWindow,
    maxTokens
  }
}

/**
 * Fallback Model for a custom id under a compatible provider. Defaults are deliberately
 * conservative because we know nothing about the model: reasoning is assumed true (callers can
 * still opt out per-call), text+image input, zero cost, and a modest 128k window / 8k output cap
 * so context-overflow handling has a sane bound to work against.
 */
function syntheticModel(entry: LlmProviderCatalogEntry, id: string): Model {
  return {
    id,
    name: id,
    api: entry.api,
    provider: entry.id,
    baseUrl: entry.baseUrl,
    reasoning: true,
    input: ['text', 'image'],
    cost: zeroCost,
    contextWindow: 128000,
    maxTokens: 8192
  }
}

/**
 * Deep-ish clone of a catalog model so callers can mutate runtime fields (headers, compat,
 * cost, sdkModel) without corrupting the shared catalog singleton. Nested objects/arrays are
 * copied; the rest are primitives that copy by value via the spread.
 */
function cloneModel<TApi extends Api>(item: Model<TApi>): Model<TApi> {
  return {
    ...item,
    input: [...item.input],
    cost: { ...item.cost },
    headers: item.headers ? { ...item.headers } : undefined,
    compat: item.compat ? { ...item.compat } : undefined
  }
}
