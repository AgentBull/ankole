import { createAmazonBedrock } from './providers/amazon-bedrock'
import { createAnthropic } from './providers/anthropic'
import { createGoogle } from './providers/google'
import { createGoogleVertex } from './providers/google-vertex'
import { createMistral } from './providers/mistral'
import { createOpenAI } from './providers/openai'
import { createOpenAICompatible } from './providers/openai-compatible'
import type { LanguageModel } from './types'
import type { Api, Model } from './bullx'

export type LlmProviderKind =
  | 'openai'
  | 'anthropic'
  | 'google'
  | 'google-vertex'
  | 'mistral'
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

export interface LlmProviderCatalogEntry {
  id: string
  name: string
  baseUrl: string
  api: Api
  models: Model[]
  compatible?: boolean
}

export interface CreateLanguageModelInput {
  llmProvider: string
  model: Model
  apiKey: string
  baseUrl?: string | null
  headers?: Record<string, string>
  providerOptions?: Record<string, unknown>
}

const zeroCost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }

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
  provider('mistral', 'Mistral AI', 'https://api.mistral.ai/v1', 'mistral-conversations', [
    model('mistral-large-latest', 'Mistral Large', 'mistral', 'mistral-conversations', false, 128000, 8192),
    model('codestral-latest', 'Codestral', 'mistral', 'mistral-conversations', false, 256000, 8192)
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

export function getProviders(): string[] {
  return catalog.map(entry => entry.id)
}

export function getModels(llmProvider: string): Model[] {
  return getProviderEntry(llmProvider)?.models.map(cloneModel) ?? []
}

export function getModel(llmProvider: string, modelId: string): Model | undefined {
  const entry = getProviderEntry(llmProvider)
  if (!entry) return undefined
  const found = entry.models.find(item => item.id === modelId)
  return found ? cloneModel(found) : syntheticModel(entry, modelId)
}

export function getProviderEntry(llmProvider: string): LlmProviderCatalogEntry | undefined {
  return catalog.find(entry => entry.id === llmProvider)
}

export function createLanguageModel(input: CreateLanguageModelInput): LanguageModel {
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
    case 'mistral':
      return createMistral({ apiKey: input.apiKey, baseURL: baseUrl, headers })(input.model.id as never)
    case 'amazon-bedrock':
      return createAmazonBedrock({
        apiKey: input.apiKey,
        baseURL: baseUrl,
        headers,
        ...(providerOptions as Record<string, never>)
      })(input.model.id as never)
    default:
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

function provider(id: string, name: string, baseUrl: string, api: Api, models: Model[]): LlmProviderCatalogEntry {
  return { id, name, baseUrl, api, models: models.map(item => ({ ...item, baseUrl: item.baseUrl || baseUrl })) }
}

function compatibleProvider(id: string, name: string, baseUrl: string, models: Model[] = []): LlmProviderCatalogEntry {
  return {
    id,
    name,
    baseUrl,
    api: 'openai-completions',
    models: models.map(item => ({ ...item, baseUrl: item.baseUrl || baseUrl })),
    compatible: true
  }
}

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

function cloneModel<TApi extends Api>(item: Model<TApi>): Model<TApi> {
  return {
    ...item,
    input: [...item.input],
    cost: { ...item.cost },
    headers: item.headers ? { ...item.headers } : undefined,
    compat: item.compat ? { ...item.compat } : undefined
  }
}
