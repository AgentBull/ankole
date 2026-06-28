import type { TurnStart } from '../actor_lane'
import { getModel } from '../llm/catalog'
import type { Model } from '../llm/ankole'
import type { ProviderOptions } from '../llm/provider-utils'
import { createAnthropic } from '../llm/providers/anthropic'
import { createGoogle } from '../llm/providers/google'
import { createOpenAI } from '../llm/providers/openai'
import { createOpenAICompatible } from '../llm/providers/openai-compatible'
import type { LanguageModel } from '../llm/types'
import type { LlmProviderCredentialResponse } from '../rpc_lane'
import { isRecord, recordArg, stringArg, stringRecord } from '../common/json-utils'

export function assertCredentialMatchesTurn(
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

export function runtimeModelFromCredential(credential: LlmProviderCredentialResponse): Model {
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

export function providerOptionsFromCredential(
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

function openAIAccountHeaders(
  options: LlmProviderCredentialResponse['connection_options_json']
): Record<string, string> {
  const headers: Record<string, string> = {}
  const organization = stringArg(options ?? {}, 'organization')
  const project = stringArg(options ?? {}, 'project')
  if (organization) headers['OpenAI-Organization'] = organization
  if (project) headers['OpenAI-Project'] = project
  return headers
}
