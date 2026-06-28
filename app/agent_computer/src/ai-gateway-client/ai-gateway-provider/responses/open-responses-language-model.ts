import {
  APICallError,
  type JSONValue,
  type LanguageModel,
  type LanguageModelPrompt,
  type LanguageModelCallOptions,
  type LanguageModelContent,
  type LanguageModelFinishReason,
  type LanguageModelGenerateResult,
  type LanguageModelStreamPart,
  type LanguageModelStreamResult,
  type LanguageModelToolApprovalRequest,
  type SharedProviderMetadata,
  type SharedWarning
} from '@/ai-gateway-client/provider'
import {
  combineHeaders,
  createEventSourceResponseHandler,
  createJsonResponseHandler,
  createToolNameMapping,
  generateId,
  isCustomReasoning,
  parseProviderOptions,
  postJsonToApi,
  serializeModelOptions,
  WORKFLOW_DESERIALIZE,
  WORKFLOW_SERIALIZE,
  type ParseResult
} from '@/ai-gateway-client/provider-utils'
import type { OpenResponsesConfig } from '../open-responses-config'
import { openResponsesFailedResponseHandler } from '../open-responses-error'
import { getOpenResponsesLanguageModelCapabilities } from '../open-responses-language-model-capabilities'
import { throwIfOpenResponsesStreamErrorBeforeOutput } from '../open-responses-stream-error'
import { convertOpenResponsesUsage, type OpenResponsesUsage } from './convert-open-responses-usage'
import { convertToOpenResponsesInput } from './convert-to-open-responses-input'
import { mapOpenResponsesFinishReason } from './map-open-responses-finish-reason'
import {
  openResponsesChunkSchema,
  openResponsesResponseSchema,
  type OpenResponsesChunk,
  type OpenResponsesIncludeOptions,
  type OpenResponsesIncludeValue,
  type OpenResponsesLogprobs,
  type OpenResponsesWebSearchAction,
  type OpenResponsesApplyPatchOperationDiffDeltaChunk,
  type OpenResponsesApplyPatchOperationDiffDoneChunk
} from './open-responses-api'
import {
  openResponsesLanguageModelOptionsSchema,
  TOP_LOGPROBS_MAX,
  type OpenResponsesModelId
} from './open-responses-language-model-options'
import { prepareResponsesTools } from './open-responses-prepare-tools'
import type {
  ResponsesCompactionProviderMetadata,
  ResponsesProviderMetadata,
  ResponsesReasoningProviderMetadata,
  ResponsesSourceDocumentProviderMetadata,
  ResponsesTextProviderMetadata
} from './open-responses-provider-metadata'

type WebSearchOutput = {
  action?:
    | {
        type: 'search'
        query?: string
        queries?: string[]
      }
    | {
        type: 'openPage'
        url?: string | null
      }
    | {
        type: 'findInPage'
        url?: string | null
        pattern?: string | null
      }
  sources?: Array<{ type: 'url'; url: string } | { type: 'api'; name: string }>
}

/**
 * Extracts a mapping from MCP approval request IDs to their corresponding tool call IDs
 * from the prompt. When an MCP tool requires approval, we generate a tool call ID to track
 * the pending approval in our system. When the user responds to the approval (and we
 * continue the conversation), we need to map the approval request ID back to our tool call ID
 * so that tool results reference the correct tool call.
 */
function extractApprovalRequestIdToToolCallIdMapping(prompt: LanguageModelPrompt): Record<string, string> {
  const mapping: Record<string, string> = {}
  for (const message of prompt) {
    if (message.role !== 'assistant') continue
    for (const part of message.content) {
      if (part.type !== 'tool-call') continue
      const approvalRequestId = part.providerOptions?.openai?.approvalRequestId as string | undefined
      if (approvalRequestId != null) {
        mapping[approvalRequestId] = part.toolCallId
      }
    }
  }
  return mapping
}

/** Implements the OpenResponses API adapter that Ankole uses for first-class OpenResponses reasoning models. */
export class OpenResponsesLanguageModel implements LanguageModel {
  readonly modelId: OpenResponsesModelId

  private readonly config: OpenResponsesConfig

  static [WORKFLOW_SERIALIZE](model: OpenResponsesLanguageModel) {
    return serializeModelOptions({
      modelId: model.modelId,
      config: model.config
    })
  }

  static [WORKFLOW_DESERIALIZE](options: { modelId: OpenResponsesModelId; config: OpenResponsesConfig }) {
    return new OpenResponsesLanguageModel(options.modelId, options.config)
  }

  constructor(modelId: OpenResponsesModelId, config: OpenResponsesConfig) {
    this.modelId = modelId
    this.config = config
  }

  readonly supportedUrls: Record<string, RegExp[]> = {
    'image/*': [/^https?:\/\/.*$/],
    'application/pdf': [/^https?:\/\/.*$/]
  }

  get provider(): string {
    return this.config.provider
  }

  private async getArgs({
    maxOutputTokens,
    temperature,
    stopSequences,
    topP,
    topK,
    presencePenalty,
    frequencyPenalty,
    seed,
    prompt,
    reasoning,
    providerOptions,
    tools,
    toolChoice,
    responseFormat
  }: LanguageModelCallOptions) {
    const warnings: SharedWarning[] = []
    const modelCapabilities = getOpenResponsesLanguageModelCapabilities(this.modelId)

    if (topK != null) {
      warnings.push({ type: 'unsupported', feature: 'topK' })
    }

    if (seed != null) {
      warnings.push({ type: 'unsupported', feature: 'seed' })
    }

    if (presencePenalty != null) {
      warnings.push({ type: 'unsupported', feature: 'presencePenalty' })
    }

    if (frequencyPenalty != null) {
      warnings.push({ type: 'unsupported', feature: 'frequencyPenalty' })
    }

    if (stopSequences != null) {
      warnings.push({ type: 'unsupported', feature: 'stopSequences' })
    }

    const providerOptionsName = this.config.provider.includes('azure') ? 'azure' : 'openai'
    let openResponsesOptions = await parseProviderOptions({
      provider: providerOptionsName,
      providerOptions,
      schema: openResponsesLanguageModelOptionsSchema
    })

    if (openResponsesOptions == null && providerOptionsName !== 'openai') {
      openResponsesOptions = await parseProviderOptions({
        provider: 'openai',
        providerOptions,
        schema: openResponsesLanguageModelOptionsSchema
      })
    }

    const resolvedReasoningEffort =
      openResponsesOptions?.reasoningEffort ?? (isCustomReasoning(reasoning) ? reasoning : undefined)
    const resolvedReasoningSummary =
      openResponsesOptions?.reasoningSummary !== undefined
        ? openResponsesOptions.reasoningSummary
        : resolvedReasoningEffort != null && resolvedReasoningEffort !== 'none'
          ? 'detailed'
          : undefined

    const isReasoningModel = openResponsesOptions?.forceReasoning ?? modelCapabilities.isReasoningModel

    if (openResponsesOptions?.conversation && openResponsesOptions?.previousResponseId) {
      warnings.push({
        type: 'unsupported',
        feature: 'conversation',
        details: 'conversation and previousResponseId cannot be used together'
      })
    }

    const toolNameMapping = createToolNameMapping({ tools, providerToolNames: {} })

    const {
      tools: responsesTools,
      toolChoice: responsesToolChoice,
      toolWarnings
    } = await prepareResponsesTools({
      tools,
      toolChoice,
      allowedTools: openResponsesOptions?.allowedTools ?? undefined,
      toolNameMapping
    })

    const { input, warnings: inputWarnings } = await convertToOpenResponsesInput({
      prompt,
      toolNameMapping,
      systemMessageMode:
        openResponsesOptions?.systemMessageMode ??
        (isReasoningModel ? 'developer' : modelCapabilities.systemMessageMode),
      providerOptionsName,
      passThroughUnsupportedFiles: openResponsesOptions?.passThroughUnsupportedFiles ?? false,
      store: openResponsesOptions?.store ?? true,
      hasConversation: openResponsesOptions?.conversation != null,
      hasPreviousResponseId: openResponsesOptions?.previousResponseId != null
    })

    warnings.push(...inputWarnings)

    const strictJsonSchema = openResponsesOptions?.strictJsonSchema ?? true

    let include: OpenResponsesIncludeOptions = openResponsesOptions?.include

    function addInclude(key: OpenResponsesIncludeValue) {
      if (include == null) {
        include = [key]
      } else if (!include.includes(key)) {
        include = [...include, key]
      }
    }

    // when logprobs are requested, automatically include them:
    const topLogprobs =
      typeof openResponsesOptions?.logprobs === 'number'
        ? openResponsesOptions?.logprobs
        : openResponsesOptions?.logprobs === true
          ? TOP_LOGPROBS_MAX
          : undefined

    if (topLogprobs) {
      addInclude('message.output_text.logprobs')
    }

    const webSearchToolName = undefined

    const store = openResponsesOptions?.store

    // store defaults to true in the OpenResponses API, so check for false exactly:
    if (store === false && isReasoningModel) {
      addInclude('reasoning.encrypted_content')
    }

    const baseArgs = {
      model: this.modelId,
      input,
      temperature,
      top_p: topP,
      max_output_tokens: maxOutputTokens,

      ...((responseFormat?.type === 'json' || openResponsesOptions?.textVerbosity) && {
        text: {
          ...(responseFormat?.type === 'json' && {
            format:
              responseFormat.schema != null
                ? {
                    type: 'json_schema',
                    strict: strictJsonSchema,
                    name: responseFormat.name ?? 'response',
                    description: responseFormat.description,
                    schema: responseFormat.schema
                  }
                : { type: 'json_object' }
          }),
          ...(openResponsesOptions?.textVerbosity && {
            verbosity: openResponsesOptions.textVerbosity
          })
        }
      }),

      // provider options:
      conversation: openResponsesOptions?.conversation,
      max_tool_calls: openResponsesOptions?.maxToolCalls,
      metadata: openResponsesOptions?.metadata,
      parallel_tool_calls: openResponsesOptions?.parallelToolCalls,
      previous_response_id: openResponsesOptions?.previousResponseId,
      store,
      user: openResponsesOptions?.user,
      instructions: openResponsesOptions?.instructions,
      service_tier: openResponsesOptions?.serviceTier,
      include,
      prompt_cache_key: openResponsesOptions?.promptCacheKey,
      prompt_cache_retention: openResponsesOptions?.promptCacheRetention,
      safety_identifier: openResponsesOptions?.safetyIdentifier,
      top_logprobs: topLogprobs,
      truncation: openResponsesOptions?.truncation,

      // context management (server-side compaction):
      ...(openResponsesOptions?.contextManagement && {
        context_management: openResponsesOptions.contextManagement.map(cm => ({
          type: cm.type,
          compact_threshold: cm.compactThreshold
        }))
      }),

      // model-specific settings:
      ...(isReasoningModel &&
        (resolvedReasoningEffort != null || resolvedReasoningSummary != null) && {
          reasoning: {
            ...(resolvedReasoningEffort != null && {
              effort: resolvedReasoningEffort
            }),
            ...(resolvedReasoningSummary != null && {
              summary: resolvedReasoningSummary
            })
          }
        })
    }

    // remove unsupported settings for reasoning models
    // see https://platform.openai.com/docs/guides/reasoning#limitations
    if (isReasoningModel) {
      // when reasoning effort is none, gpt-5.1 models allow temperature, topP, logprobs
      //  https://platform.openai.com/docs/guides/latest-model#gpt-5-1-parameter-compatibility
      if (!(resolvedReasoningEffort === 'none' && modelCapabilities.supportsNonReasoningParameters)) {
        if (baseArgs.temperature != null) {
          baseArgs.temperature = undefined
          warnings.push({
            type: 'unsupported',
            feature: 'temperature',
            details: 'temperature is not supported for reasoning models'
          })
        }

        if (baseArgs.top_p != null) {
          baseArgs.top_p = undefined
          warnings.push({
            type: 'unsupported',
            feature: 'topP',
            details: 'topP is not supported for reasoning models'
          })
        }
      }
    } else {
      if (openResponsesOptions?.reasoningEffort != null) {
        warnings.push({
          type: 'unsupported',
          feature: 'reasoningEffort',
          details: 'reasoningEffort is not supported for non-reasoning models'
        })
      }

      if (openResponsesOptions?.reasoningSummary != null) {
        warnings.push({
          type: 'unsupported',
          feature: 'reasoningSummary',
          details: 'reasoningSummary is not supported for non-reasoning models'
        })
      }
    }

    // Validate flex processing support
    if (openResponsesOptions?.serviceTier === 'flex' && !modelCapabilities.supportsFlexProcessing) {
      warnings.push({
        type: 'unsupported',
        feature: 'serviceTier',
        details: 'flex processing is only available for o3, o4-mini, and gpt-5 models'
      })
      // Remove from args if not supported
      delete (baseArgs as any).service_tier
    }

    // Validate priority processing support
    if (openResponsesOptions?.serviceTier === 'priority' && !modelCapabilities.supportsPriorityProcessing) {
      warnings.push({
        type: 'unsupported',
        feature: 'serviceTier',
        details:
          'priority processing is only available for supported models (gpt-4, gpt-5, gpt-5-mini, o3, o4-mini) and requires Enterprise access. gpt-5-nano is not supported'
      })
      // Remove from args if not supported
      delete (baseArgs as any).service_tier
    }

    const isShellProviderExecuted = false

    return {
      webSearchToolName,
      args: {
        ...baseArgs,
        tools: responsesTools,
        tool_choice: responsesToolChoice
      },
      warnings: [...warnings, ...toolWarnings],
      store,
      toolNameMapping,
      providerOptionsName,
      isShellProviderExecuted
    }
  }

  /** Sends one non-streaming Responses request and maps provider output items back into AI SDK parts. */
  async doGenerate(options: LanguageModelCallOptions): Promise<LanguageModelGenerateResult> {
    const {
      args: body,
      warnings,
      webSearchToolName,
      toolNameMapping,
      providerOptionsName,
      isShellProviderExecuted
    } = await this.getArgs(options)
    const url = this.config.url({
      path: '/responses',
      modelId: this.modelId
    })

    const approvalRequestIdToDummyToolCallIdFromPrompt = extractApprovalRequestIdToToolCallIdMapping(options.prompt)

    const {
      responseHeaders,
      value: response,
      rawValue: rawResponse
    } = await postJsonToApi({
      url,
      headers: combineHeaders(this.config.headers?.(), options.headers),
      body,
      failedResponseHandler: openResponsesFailedResponseHandler,
      successfulResponseHandler: createJsonResponseHandler(openResponsesResponseSchema),
      abortSignal: options.abortSignal,
      fetch: this.config.fetch
    })

    if (response.error) {
      throw new APICallError({
        message: response.error.message,
        url,
        requestBodyValues: body,
        statusCode: 400,
        responseHeaders,
        responseBody: rawResponse as string,
        isRetryable: false
      })
    }

    const content: Array<LanguageModelContent> = []
    const logprobs: Array<OpenResponsesLogprobs> = []

    // flag that checks if there have been client-side tool calls (not executed by provider)
    let hasFunctionCall = false
    const hostedToolSearchCallIds: string[] = []

    // map response content to content array (defined when there is no error)
    for (const part of response.output!) {
      switch (part.type) {
        case 'reasoning': {
          // when there are no summary parts, we need to add an empty reasoning part:
          if (part.summary.length === 0) {
            part.summary.push({ type: 'summary_text', text: '' })
          }

          for (const summary of part.summary) {
            content.push({
              type: 'reasoning' as const,
              text: summary.text,
              providerMetadata: {
                [providerOptionsName]: {
                  itemId: part.id,
                  reasoningEncryptedContent: part.encrypted_content ?? null
                } satisfies ResponsesReasoningProviderMetadata
              }
            })
          }
          break
        }

        case 'image_generation_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('image_generation'),
            input: '{}',
            providerExecuted: true
          })

          content.push({
            type: 'tool-result',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('image_generation'),
            result: {
              result: part.result
            }
          })

          break
        }

        case 'tool_search_call': {
          const toolCallId = part.call_id ?? part.id
          const isHosted = part.execution === 'server'

          if (isHosted) {
            hostedToolSearchCallIds.push(toolCallId)
          }

          content.push({
            type: 'tool-call',
            toolCallId,
            toolName: toolNameMapping.toCustomToolName('tool_search'),
            input: JSON.stringify({
              arguments: part.arguments,
              call_id: part.call_id
            }),
            ...(isHosted ? { providerExecuted: true } : {}),
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })

          break
        }

        case 'tool_search_output': {
          const toolCallId = part.call_id ?? hostedToolSearchCallIds.shift() ?? part.id

          content.push({
            type: 'tool-result',
            toolCallId,
            toolName: toolNameMapping.toCustomToolName('tool_search'),
            result: {
              tools: part.tools
            },
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })

          break
        }

        case 'local_shell_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.call_id,
            toolName: toolNameMapping.toCustomToolName('local_shell'),
            input: JSON.stringify({
              action: part.action
            }),
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })

          break
        }

        case 'shell_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.call_id,
            toolName: toolNameMapping.toCustomToolName('shell'),
            input: JSON.stringify({
              action: {
                commands: part.action.commands
              }
            }),
            ...(isShellProviderExecuted && { providerExecuted: true }),
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })

          break
        }

        case 'shell_call_output': {
          content.push({
            type: 'tool-result',
            toolCallId: part.call_id,
            toolName: toolNameMapping.toCustomToolName('shell'),
            result: {
              output: part.output.map(item => ({
                stdout: item.stdout,
                stderr: item.stderr,
                outcome:
                  item.outcome.type === 'exit'
                    ? {
                        type: 'exit' as const,
                        exitCode: item.outcome.exit_code
                      }
                    : { type: 'timeout' as const }
              }))
            }
          })
          break
        }

        case 'message': {
          for (const contentPart of part.content) {
            if (options.providerOptions?.[providerOptionsName]?.logprobs && contentPart.logprobs) {
              logprobs.push(contentPart.logprobs)
            }

            const providerMetadata: SharedProviderMetadata[string] = {
              itemId: part.id,
              ...(part.phase != null && { phase: part.phase }),
              ...(contentPart.annotations.length > 0 && {
                annotations: contentPart.annotations
              })
            } satisfies ResponsesTextProviderMetadata

            content.push({
              type: 'text',
              text: contentPart.text,
              providerMetadata: {
                [providerOptionsName]: providerMetadata
              }
            })

            for (const annotation of contentPart.annotations) {
              if (annotation.type === 'url_citation') {
                content.push({
                  type: 'source',
                  sourceType: 'url',
                  id: this.config.generateId?.() ?? generateId(),
                  url: annotation.url,
                  title: annotation.title
                })
              } else if (annotation.type === 'file_citation') {
                content.push({
                  type: 'source',
                  sourceType: 'document',
                  id: this.config.generateId?.() ?? generateId(),
                  mediaType: 'text/plain',
                  title: annotation.filename,
                  filename: annotation.filename,
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: annotation.type,
                      fileId: annotation.file_id,
                      index: annotation.index
                    } satisfies Extract<ResponsesSourceDocumentProviderMetadata, { type: 'file_citation' }>
                  }
                })
              } else if (annotation.type === 'container_file_citation') {
                content.push({
                  type: 'source',
                  sourceType: 'document',
                  id: this.config.generateId?.() ?? generateId(),
                  mediaType: 'text/plain',
                  title: annotation.filename,
                  filename: annotation.filename,
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: annotation.type,
                      fileId: annotation.file_id,
                      containerId: annotation.container_id
                    } satisfies Extract<ResponsesSourceDocumentProviderMetadata, { type: 'container_file_citation' }>
                  }
                })
              } else if (annotation.type === 'file_path') {
                content.push({
                  type: 'source',
                  sourceType: 'document',
                  id: this.config.generateId?.() ?? generateId(),
                  mediaType: 'application/octet-stream',
                  title: annotation.file_id,
                  filename: annotation.file_id,
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: annotation.type,
                      fileId: annotation.file_id,
                      index: annotation.index
                    } satisfies Extract<ResponsesSourceDocumentProviderMetadata, { type: 'file_path' }>
                  }
                })
              }
            }
          }

          break
        }

        case 'function_call': {
          hasFunctionCall = true

          content.push({
            type: 'tool-call',
            toolCallId: part.call_id,
            toolName: part.name,
            input: part.arguments,
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id,
                ...(part.namespace != null && { namespace: part.namespace })
              }
            }
          })
          break
        }

        case 'custom_tool_call': {
          hasFunctionCall = true
          const toolName = toolNameMapping.toCustomToolName(part.name)

          content.push({
            type: 'tool-call',
            toolCallId: part.call_id,
            toolName,
            input: JSON.stringify(part.input),
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })
          break
        }

        case 'web_search_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName(webSearchToolName ?? 'web_search'),
            input: JSON.stringify({}),
            providerExecuted: true
          })

          content.push({
            type: 'tool-result',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName(webSearchToolName ?? 'web_search'),
            result: mapWebSearchOutput(part.action)
          })

          break
        }

        case 'mcp_call': {
          const toolCallId =
            part.approval_request_id != null
              ? (approvalRequestIdToDummyToolCallIdFromPrompt[part.approval_request_id] ?? part.id)
              : part.id

          const toolName = `mcp.${part.name}`

          content.push({
            type: 'tool-call',
            toolCallId,
            toolName,
            input: part.arguments,
            providerExecuted: true,
            dynamic: true
          })

          content.push({
            type: 'tool-result',
            toolCallId,
            toolName,
            result: {
              type: 'call',
              serverLabel: part.server_label,
              name: part.name,
              arguments: part.arguments,
              ...(part.output != null ? { output: part.output } : {}),
              ...(part.error != null ? { error: part.error as unknown as JSONValue } : {})
            },
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })
          break
        }

        case 'mcp_list_tools': {
          // skip
          break
        }

        case 'mcp_approval_request': {
          const approvalRequestId = part.approval_request_id ?? part.id
          const dummyToolCallId = this.config.generateId?.() ?? generateId()
          const toolName = `mcp.${part.name}`

          content.push({
            type: 'tool-call',
            toolCallId: dummyToolCallId,
            toolName,
            input: part.arguments,
            providerExecuted: true,
            dynamic: true
          })

          content.push({
            type: 'tool-approval-request',
            approvalId: approvalRequestId,
            toolCallId: dummyToolCallId
          } satisfies LanguageModelToolApprovalRequest)
          break
        }

        case 'computer_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('computer_use'),
            input: '',
            providerExecuted: true
          })

          content.push({
            type: 'tool-result',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('computer_use'),
            result: {
              type: 'computer_use_tool_result',
              status: part.status || 'completed'
            }
          })
          break
        }

        case 'file_search_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('file_search'),
            input: '{}',
            providerExecuted: true
          })

          content.push({
            type: 'tool-result',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('file_search'),
            result: {
              queries: part.queries,
              results:
                part.results?.map(result => ({
                  attributes: result.attributes,
                  fileId: result.file_id,
                  filename: result.filename,
                  score: result.score,
                  text: result.text
                })) ?? null
            }
          })
          break
        }

        case 'code_interpreter_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('code_interpreter'),
            input: JSON.stringify({
              code: part.code,
              containerId: part.container_id
            }),
            providerExecuted: true
          })

          content.push({
            type: 'tool-result',
            toolCallId: part.id,
            toolName: toolNameMapping.toCustomToolName('code_interpreter'),
            result: {
              outputs: part.outputs
            }
          })
          break
        }

        case 'apply_patch_call': {
          content.push({
            type: 'tool-call',
            toolCallId: part.call_id,
            toolName: toolNameMapping.toCustomToolName('apply_patch'),
            input: JSON.stringify({
              callId: part.call_id,
              operation: part.operation
            }),
            providerMetadata: {
              [providerOptionsName]: {
                itemId: part.id
              }
            }
          })

          break
        }

        case 'compaction': {
          content.push({
            type: 'custom',
            kind: 'openai.compaction',
            providerMetadata: {
              [providerOptionsName]: {
                type: 'compaction',
                itemId: part.id,
                encryptedContent: part.encrypted_content
              } satisfies ResponsesCompactionProviderMetadata
            }
          })
          break
        }
      }
    }

    const providerMetadata: SharedProviderMetadata = {
      [providerOptionsName]: {
        responseId: response.id,
        ...(logprobs.length > 0 ? { logprobs } : {}),
        ...(typeof response.service_tier === 'string' ? { serviceTier: response.service_tier } : {})
      } satisfies ResponsesProviderMetadata
    }

    const usage = response.usage! // defined when there is no error

    return {
      content,
      finishReason: {
        unified: mapOpenResponsesFinishReason({
          finishReason: response.incomplete_details?.reason,
          hasFunctionCall
        }),
        raw: response.incomplete_details?.reason ?? undefined
      },
      usage: convertOpenResponsesUsage(usage),
      request: { body },
      response: {
        id: response.id,
        timestamp: new Date(response.created_at! * 1000),
        modelId: response.model,
        headers: responseHeaders,
        body: rawResponse
      },
      providerMetadata,
      warnings
    }
  }

  /** Streams Responses events while preserving tool-call ids, reasoning metadata, and provider-executed outputs. */
  async doStream(options: LanguageModelCallOptions): Promise<LanguageModelStreamResult> {
    const {
      args: body,
      warnings,
      webSearchToolName,
      toolNameMapping,
      store,
      providerOptionsName,
      isShellProviderExecuted
    } = await this.getArgs(options)

    const url = this.config.url({
      path: '/responses',
      modelId: this.modelId
    })

    const { responseHeaders, value: response } = await postJsonToApi({
      url,
      headers: combineHeaders(this.config.headers?.(), options.headers),
      body: {
        ...body,
        stream: true
      },
      failedResponseHandler: openResponsesFailedResponseHandler,
      successfulResponseHandler: createEventSourceResponseHandler(openResponsesChunkSchema),
      abortSignal: options.abortSignal,
      fetch: this.config.fetch
    })

    const checkedResponse = await throwIfOpenResponsesStreamErrorBeforeOutput({
      stream: response,
      getError: chunk =>
        isErrorChunk(chunk) || (isResponseFailedChunk(chunk) && chunk.response.error != null) ? chunk : undefined,
      isOutputChunk: isResponseOutputChunk,
      url,
      requestBodyValues: body,
      responseHeaders
    })

    const approvalRequestIdToDummyToolCallIdFromPrompt = extractApprovalRequestIdToToolCallIdMapping(options.prompt)

    const approvalRequestIdToDummyToolCallIdFromStream = new Map<string, string>()
    const createId = () => this.config.generateId?.() ?? generateId()

    let finishReason: LanguageModelFinishReason = {
      unified: 'other',
      raw: undefined
    }
    let usage: OpenResponsesUsage | undefined = undefined
    const logprobs: Array<OpenResponsesLogprobs> = []
    let responseId: string | null = null

    const ongoingToolCalls: Record<
      number,
      | {
          toolName: string
          toolCallId: string
          codeInterpreter?: {
            containerId: string
          }
          applyPatch?: {
            hasDiff: boolean
            endEmitted: boolean
          }
          toolSearchExecution?: 'server' | 'client'
        }
      | undefined
    > = {}

    // set annotations in 'text-end' part providerMetadata.
    const ongoingAnnotations: Array<
      Extract<OpenResponsesChunk, { type: 'response.output_text.annotation.added' }>['annotation']
    > = []

    // track the phase of the current message being streamed
    let activeMessagePhase: 'commentary' | 'final_answer' | undefined

    // flag that checks if there have been client-side tool calls (not executed by provider)
    let hasFunctionCall = false

    const activeReasoning: Record<
      string,
      {
        encryptedContent?: string | null
        // summary index as string to reasoning part state:
        summaryParts: Record<string, 'active' | 'can-conclude' | 'concluded'>
      }
    > = {}

    let serviceTier: string | undefined
    const hostedToolSearchCallIds: string[] = []
    let encounteredStreamError = false

    const result = {
      stream: checkedResponse.pipeThrough(
        new TransformStream<ParseResult<OpenResponsesChunk>, LanguageModelStreamPart>({
          start(controller) {
            controller.enqueue({ type: 'stream-start', warnings })
          },

          transform(chunk, controller) {
            if (options.includeRawChunks) {
              controller.enqueue({ type: 'raw', rawValue: chunk.rawValue })
            }

            // handle failed chunk parsing / validation:
            if (!chunk.success) {
              finishReason = { unified: 'error', raw: undefined }
              controller.enqueue({ type: 'error', error: chunk.error })
              return
            }

            const value = chunk.value

            if (isResponseOutputItemAddedChunk(value)) {
              if (value.item.type === 'function_call') {
                ongoingToolCalls[value.output_index] = {
                  toolName: value.item.name,
                  toolCallId: value.item.call_id
                }

                controller.enqueue({
                  type: 'tool-input-start',
                  id: value.item.call_id,
                  toolName: value.item.name
                })
              } else if (value.item.type === 'custom_tool_call') {
                const toolName = toolNameMapping.toCustomToolName(value.item.name)
                ongoingToolCalls[value.output_index] = {
                  toolName,
                  toolCallId: value.item.call_id
                }

                controller.enqueue({
                  type: 'tool-input-start',
                  id: value.item.call_id,
                  toolName
                })
              } else if (value.item.type === 'web_search_call') {
                ongoingToolCalls[value.output_index] = {
                  toolName: toolNameMapping.toCustomToolName(webSearchToolName ?? 'web_search'),
                  toolCallId: value.item.id
                }

                controller.enqueue({
                  type: 'tool-input-start',
                  id: value.item.id,
                  toolName: toolNameMapping.toCustomToolName(webSearchToolName ?? 'web_search'),
                  providerExecuted: true
                })

                controller.enqueue({
                  type: 'tool-input-end',
                  id: value.item.id
                })

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName(webSearchToolName ?? 'web_search'),
                  input: JSON.stringify({}),
                  providerExecuted: true
                })
              } else if (value.item.type === 'computer_call') {
                ongoingToolCalls[value.output_index] = {
                  toolName: toolNameMapping.toCustomToolName('computer_use'),
                  toolCallId: value.item.id
                }

                controller.enqueue({
                  type: 'tool-input-start',
                  id: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('computer_use'),
                  providerExecuted: true
                })
              } else if (value.item.type === 'code_interpreter_call') {
                ongoingToolCalls[value.output_index] = {
                  toolName: toolNameMapping.toCustomToolName('code_interpreter'),
                  toolCallId: value.item.id,
                  codeInterpreter: {
                    containerId: value.item.container_id
                  }
                }

                controller.enqueue({
                  type: 'tool-input-start',
                  id: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('code_interpreter'),
                  providerExecuted: true
                })

                controller.enqueue({
                  type: 'tool-input-delta',
                  id: value.item.id,
                  delta: `{"containerId":"${value.item.container_id}","code":"`
                })
              } else if (value.item.type === 'file_search_call') {
                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('file_search'),
                  input: '{}',
                  providerExecuted: true
                })
              } else if (value.item.type === 'image_generation_call') {
                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('image_generation'),
                  input: '{}',
                  providerExecuted: true
                })
              } else if (value.item.type === 'tool_search_call') {
                const toolCallId = value.item.id
                const toolName = toolNameMapping.toCustomToolName('tool_search')
                const isHosted = value.item.execution === 'server'

                ongoingToolCalls[value.output_index] = {
                  toolName,
                  toolCallId,
                  toolSearchExecution: value.item.execution ?? 'server'
                }

                if (isHosted) {
                  controller.enqueue({
                    type: 'tool-input-start',
                    id: toolCallId,
                    toolName,
                    providerExecuted: true
                  })
                }
              } else if (value.item.type === 'tool_search_output') {
                // handled on output_item.done so we can pair it with the call
              } else if (
                value.item.type === 'mcp_call' ||
                value.item.type === 'mcp_list_tools' ||
                value.item.type === 'mcp_approval_request'
              ) {
                // Emit MCP tool-call/approval parts on output_item.done instead, so we can:
                // - alias mcp_call IDs when an approval_request_id is present
                // - emit a proper tool-approval-request part for MCP approvals
              } else if (value.item.type === 'apply_patch_call') {
                const { call_id: callId, operation } = value.item

                ongoingToolCalls[value.output_index] = {
                  toolName: toolNameMapping.toCustomToolName('apply_patch'),
                  toolCallId: callId,
                  applyPatch: {
                    // delete_file doesn't have diff
                    hasDiff: operation.type === 'delete_file',
                    endEmitted: operation.type === 'delete_file'
                  }
                }

                controller.enqueue({
                  type: 'tool-input-start',
                  id: callId,
                  toolName: toolNameMapping.toCustomToolName('apply_patch')
                })

                if (operation.type === 'delete_file') {
                  const inputString = JSON.stringify({
                    callId,
                    operation
                  })

                  controller.enqueue({
                    type: 'tool-input-delta',
                    id: callId,
                    delta: inputString
                  })

                  controller.enqueue({
                    type: 'tool-input-end',
                    id: callId
                  })
                } else {
                  controller.enqueue({
                    type: 'tool-input-delta',
                    id: callId,
                    delta: `{"callId":"${escapeJSONDelta(callId)}","operation":{"type":"${escapeJSONDelta(operation.type)}","path":"${escapeJSONDelta(operation.path)}","diff":"`
                  })
                }
              } else if (value.item.type === 'shell_call') {
                ongoingToolCalls[value.output_index] = {
                  toolName: toolNameMapping.toCustomToolName('shell'),
                  toolCallId: value.item.call_id
                }
              } else if (value.item.type === 'shell_call_output') {
                // shell_call_output is handled in output_item.done
              } else if (value.item.type === 'message') {
                ongoingAnnotations.splice(0, ongoingAnnotations.length)
                activeMessagePhase = value.item.phase ?? undefined
                controller.enqueue({
                  type: 'text-start',
                  id: value.item.id,
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id,
                      ...(value.item.phase != null && {
                        phase: value.item.phase
                      })
                    }
                  }
                })
              } else if (isResponseOutputItemAddedChunk(value) && value.item.type === 'reasoning') {
                activeReasoning[value.item.id] = {
                  encryptedContent: value.item.encrypted_content,
                  summaryParts: { 0: 'active' }
                }

                controller.enqueue({
                  type: 'reasoning-start',
                  id: `${value.item.id}:0`,
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id,
                      reasoningEncryptedContent: value.item.encrypted_content ?? null
                    } satisfies ResponsesReasoningProviderMetadata
                  }
                })
              }
            } else if (isResponseOutputItemDoneChunk(value)) {
              if (value.item.type === 'message') {
                const phase = value.item.phase ?? activeMessagePhase
                activeMessagePhase = undefined
                controller.enqueue({
                  type: 'text-end',
                  id: value.item.id,
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id,
                      ...(phase != null && { phase }),
                      ...(ongoingAnnotations.length > 0 && {
                        annotations: ongoingAnnotations
                      })
                    } satisfies ResponsesTextProviderMetadata
                  }
                })
              } else if (value.item.type === 'function_call') {
                ongoingToolCalls[value.output_index] = undefined
                hasFunctionCall = true

                controller.enqueue({
                  type: 'tool-input-end',
                  id: value.item.call_id,
                  ...(value.item.namespace != null && {
                    providerMetadata: {
                      [providerOptionsName]: {
                        namespace: value.item.namespace
                      }
                    }
                  })
                })

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.call_id,
                  toolName: value.item.name,
                  input: value.item.arguments,
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id,
                      ...(value.item.namespace != null && {
                        namespace: value.item.namespace
                      })
                    }
                  }
                })
              } else if (value.item.type === 'custom_tool_call') {
                ongoingToolCalls[value.output_index] = undefined
                hasFunctionCall = true
                const toolName = toolNameMapping.toCustomToolName(value.item.name)

                controller.enqueue({
                  type: 'tool-input-end',
                  id: value.item.call_id
                })

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.call_id,
                  toolName,
                  input: JSON.stringify(value.item.input),
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id
                    }
                  }
                })
              } else if (value.item.type === 'web_search_call') {
                ongoingToolCalls[value.output_index] = undefined

                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName(webSearchToolName ?? 'web_search'),
                  result: mapWebSearchOutput(value.item.action)
                })
              } else if (value.item.type === 'computer_call') {
                ongoingToolCalls[value.output_index] = undefined

                controller.enqueue({
                  type: 'tool-input-end',
                  id: value.item.id
                })

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('computer_use'),
                  input: '',
                  providerExecuted: true
                })

                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('computer_use'),
                  result: {
                    type: 'computer_use_tool_result',
                    status: value.item.status || 'completed'
                  }
                })
              } else if (value.item.type === 'file_search_call') {
                ongoingToolCalls[value.output_index] = undefined

                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('file_search'),
                  result: {
                    queries: value.item.queries,
                    results:
                      value.item.results?.map(result => ({
                        attributes: result.attributes,
                        fileId: result.file_id,
                        filename: result.filename,
                        score: result.score,
                        text: result.text
                      })) ?? null
                  }
                })
              } else if (value.item.type === 'code_interpreter_call') {
                ongoingToolCalls[value.output_index] = undefined

                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('code_interpreter'),
                  result: {
                    outputs: value.item.outputs
                  }
                })
              } else if (value.item.type === 'image_generation_call') {
                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: value.item.id,
                  toolName: toolNameMapping.toCustomToolName('image_generation'),
                  result: {
                    result: value.item.result
                  }
                })
              } else if (value.item.type === 'tool_search_call') {
                const toolCall = ongoingToolCalls[value.output_index]
                const isHosted = value.item.execution === 'server'

                if (toolCall != null) {
                  const toolCallId = isHosted ? toolCall.toolCallId : (value.item.call_id ?? value.item.id)

                  if (isHosted) {
                    hostedToolSearchCallIds.push(toolCallId)
                  } else {
                    controller.enqueue({
                      type: 'tool-input-start',
                      id: toolCallId,
                      toolName: toolCall.toolName
                    })
                  }

                  controller.enqueue({
                    type: 'tool-input-end',
                    id: toolCallId
                  })

                  controller.enqueue({
                    type: 'tool-call',
                    toolCallId,
                    toolName: toolCall.toolName,
                    input: JSON.stringify({
                      arguments: value.item.arguments,
                      call_id: isHosted ? null : toolCallId
                    }),
                    ...(isHosted ? { providerExecuted: true } : {}),
                    providerMetadata: {
                      [providerOptionsName]: {
                        itemId: value.item.id
                      }
                    }
                  })
                }

                ongoingToolCalls[value.output_index] = undefined
              } else if (value.item.type === 'tool_search_output') {
                const toolCallId = value.item.call_id ?? hostedToolSearchCallIds.shift() ?? value.item.id

                controller.enqueue({
                  type: 'tool-result',
                  toolCallId,
                  toolName: toolNameMapping.toCustomToolName('tool_search'),
                  result: {
                    tools: value.item.tools
                  },
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id
                    }
                  }
                })
              } else if (value.item.type === 'mcp_call') {
                ongoingToolCalls[value.output_index] = undefined

                const approvalRequestId = value.item.approval_request_id ?? undefined

                // when MCP tools require approval, we track them with our own
                // tool call IDs and then map the provider approval_request_id back to our ID so results match.
                const aliasedToolCallId =
                  approvalRequestId != null
                    ? (approvalRequestIdToDummyToolCallIdFromStream.get(approvalRequestId) ??
                      approvalRequestIdToDummyToolCallIdFromPrompt[approvalRequestId] ??
                      value.item.id)
                    : value.item.id

                const toolName = `mcp.${value.item.name}`

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: aliasedToolCallId,
                  toolName,
                  input: value.item.arguments,
                  providerExecuted: true,
                  dynamic: true
                })

                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: aliasedToolCallId,
                  toolName,
                  result: {
                    type: 'call',
                    serverLabel: value.item.server_label,
                    name: value.item.name,
                    arguments: value.item.arguments,
                    ...(value.item.output != null ? { output: value.item.output } : {}),
                    ...(value.item.error != null ? { error: value.item.error as unknown as JSONValue } : {})
                  },
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item.id
                    }
                  }
                })
              } else if (value.item.type === 'mcp_list_tools') {
                // Skip listTools - we don't expose this to the UI or send it back
                ongoingToolCalls[value.output_index] = undefined

                // skip
              } else if (value.item.type === 'apply_patch_call') {
                const toolCall = ongoingToolCalls[value.output_index]
                if (
                  toolCall?.applyPatch &&
                  !toolCall.applyPatch.endEmitted &&
                  value.item.operation.type !== 'delete_file'
                ) {
                  if (!toolCall.applyPatch.hasDiff) {
                    controller.enqueue({
                      type: 'tool-input-delta',
                      id: toolCall.toolCallId,
                      delta: escapeJSONDelta(value.item.operation.diff)
                    })
                  }

                  controller.enqueue({
                    type: 'tool-input-delta',
                    id: toolCall.toolCallId,
                    delta: '"}}'
                  })

                  controller.enqueue({
                    type: 'tool-input-end',
                    id: toolCall.toolCallId
                  })

                  toolCall.applyPatch.endEmitted = true
                }

                // Emit the final tool-call with complete diff when status is 'completed'
                if (toolCall && value.item.status === 'completed') {
                  controller.enqueue({
                    type: 'tool-call',
                    toolCallId: toolCall.toolCallId,
                    toolName: toolNameMapping.toCustomToolName('apply_patch'),
                    input: JSON.stringify({
                      callId: value.item.call_id,
                      operation: value.item.operation
                    }),
                    providerMetadata: {
                      [providerOptionsName]: {
                        itemId: value.item.id
                      }
                    }
                  })
                }

                ongoingToolCalls[value.output_index] = undefined
              } else if (value.item.type === 'mcp_approval_request') {
                ongoingToolCalls[value.output_index] = undefined

                const dummyToolCallId = createId()
                const approvalRequestId = value.item.approval_request_id ?? value.item.id
                approvalRequestIdToDummyToolCallIdFromStream.set(approvalRequestId, dummyToolCallId)

                const toolName = `mcp.${value.item.name}`

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: dummyToolCallId,
                  toolName,
                  input: value.item.arguments,
                  providerExecuted: true,
                  dynamic: true
                })

                controller.enqueue({
                  type: 'tool-approval-request',
                  approvalId: approvalRequestId,
                  toolCallId: dummyToolCallId
                })
              } else if (value.item.type === 'local_shell_call') {
                ongoingToolCalls[value.output_index] = undefined

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.call_id,
                  toolName: toolNameMapping.toCustomToolName('local_shell'),
                  input: JSON.stringify({
                    action: {
                      type: 'exec',
                      command: value.item.action.command,
                      timeoutMs: value.item.action.timeout_ms,
                      user: value.item.action.user,
                      workingDirectory: value.item.action.working_directory,
                      env: value.item.action.env
                    }
                  }),
                  providerMetadata: {
                    [providerOptionsName]: { itemId: value.item.id }
                  }
                })
              } else if (value.item.type === 'shell_call') {
                ongoingToolCalls[value.output_index] = undefined

                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: value.item.call_id,
                  toolName: toolNameMapping.toCustomToolName('shell'),
                  input: JSON.stringify({
                    action: {
                      commands: value.item.action.commands
                    }
                  }),
                  ...(isShellProviderExecuted && {
                    providerExecuted: true
                  }),
                  providerMetadata: {
                    [providerOptionsName]: { itemId: value.item.id }
                  }
                })
              } else if (value.item.type === 'shell_call_output') {
                controller.enqueue({
                  type: 'tool-result',
                  toolCallId: value.item.call_id,
                  toolName: toolNameMapping.toCustomToolName('shell'),
                  result: {
                    output: value.item.output.map(
                      (item: {
                        stdout: string
                        stderr: string
                        outcome: { type: 'exit'; exit_code: number } | { type: 'timeout' }
                      }) => ({
                        stdout: item.stdout,
                        stderr: item.stderr,
                        outcome:
                          item.outcome.type === 'exit'
                            ? {
                                type: 'exit' as const,
                                exitCode: item.outcome.exit_code
                              }
                            : { type: 'timeout' as const }
                      })
                    )
                  }
                })
              } else if (value.item.type === 'reasoning') {
                const activeReasoningPart = activeReasoning[value.item.id]

                // get all active or can-conclude summary parts' ids
                // to conclude ongoing reasoning parts:
                const summaryPartIndices = Object.entries(activeReasoningPart.summaryParts)
                  .filter(([_, status]) => status === 'active' || status === 'can-conclude')
                  .map(([summaryIndex]) => summaryIndex)

                for (const summaryIndex of summaryPartIndices) {
                  controller.enqueue({
                    type: 'reasoning-end',
                    id: `${value.item.id}:${summaryIndex}`,
                    providerMetadata: {
                      [providerOptionsName]: {
                        itemId: value.item.id,
                        reasoningEncryptedContent: value.item.encrypted_content ?? null
                      } satisfies ResponsesReasoningProviderMetadata
                    }
                  })
                }

                delete activeReasoning[value.item.id]
              } else if (value.item.type === 'compaction') {
                controller.enqueue({
                  type: 'custom',
                  kind: 'openai.compaction',
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: 'compaction',
                      itemId: value.item.id,
                      encryptedContent: value.item.encrypted_content
                    } satisfies ResponsesCompactionProviderMetadata
                  }
                })
              }
            } else if (isResponseFunctionCallArgumentsDeltaChunk(value)) {
              const toolCall = ongoingToolCalls[value.output_index]

              if (toolCall != null) {
                controller.enqueue({
                  type: 'tool-input-delta',
                  id: toolCall.toolCallId,
                  delta: value.delta
                })
              }
            } else if (isResponseCustomToolCallInputDeltaChunk(value)) {
              const toolCall = ongoingToolCalls[value.output_index]

              if (toolCall != null) {
                controller.enqueue({
                  type: 'tool-input-delta',
                  id: toolCall.toolCallId,
                  delta: value.delta
                })
              }
            } else if (isResponseApplyPatchCallOperationDiffDeltaChunk(value)) {
              const toolCall = ongoingToolCalls[value.output_index]

              if (toolCall?.applyPatch) {
                controller.enqueue({
                  type: 'tool-input-delta',
                  id: toolCall.toolCallId,
                  delta: escapeJSONDelta(value.delta)
                })

                toolCall.applyPatch.hasDiff = true
              }
            } else if (isResponseApplyPatchCallOperationDiffDoneChunk(value)) {
              const toolCall = ongoingToolCalls[value.output_index]

              if (toolCall?.applyPatch && !toolCall.applyPatch.endEmitted) {
                if (!toolCall.applyPatch.hasDiff) {
                  controller.enqueue({
                    type: 'tool-input-delta',
                    id: toolCall.toolCallId,
                    delta: escapeJSONDelta(value.diff)
                  })

                  toolCall.applyPatch.hasDiff = true
                }

                controller.enqueue({
                  type: 'tool-input-delta',
                  id: toolCall.toolCallId,
                  delta: '"}}'
                })

                controller.enqueue({
                  type: 'tool-input-end',
                  id: toolCall.toolCallId
                })

                toolCall.applyPatch.endEmitted = true
              }
            } else if (isResponseImageGenerationCallPartialImageChunk(value)) {
              controller.enqueue({
                type: 'tool-result',
                toolCallId: value.item_id,
                toolName: toolNameMapping.toCustomToolName('image_generation'),
                result: {
                  result: value.partial_image_b64
                },
                preliminary: true
              })
            } else if (isResponseCodeInterpreterCallCodeDeltaChunk(value)) {
              const toolCall = ongoingToolCalls[value.output_index]

              if (toolCall != null) {
                controller.enqueue({
                  type: 'tool-input-delta',
                  id: toolCall.toolCallId,
                  delta: escapeJSONDelta(value.delta)
                })
              }
            } else if (isResponseCodeInterpreterCallCodeDoneChunk(value)) {
              const toolCall = ongoingToolCalls[value.output_index]

              if (toolCall != null) {
                controller.enqueue({
                  type: 'tool-input-delta',
                  id: toolCall.toolCallId,
                  delta: '"}'
                })

                controller.enqueue({
                  type: 'tool-input-end',
                  id: toolCall.toolCallId
                })

                // immediately send the tool call after the input end:
                controller.enqueue({
                  type: 'tool-call',
                  toolCallId: toolCall.toolCallId,
                  toolName: toolNameMapping.toCustomToolName('code_interpreter'),
                  input: JSON.stringify({
                    code: value.code,
                    containerId: toolCall.codeInterpreter!.containerId
                  }),
                  providerExecuted: true
                })
              }
            } else if (isResponseCreatedChunk(value)) {
              responseId = value.response.id
              controller.enqueue({
                type: 'response-metadata',
                id: value.response.id,
                timestamp: new Date(value.response.created_at * 1000),
                modelId: value.response.model
              })
            } else if (isTextDeltaChunk(value)) {
              controller.enqueue({
                type: 'text-delta',
                id: value.item_id,
                delta: value.delta
              })

              if (options.providerOptions?.[providerOptionsName]?.logprobs && value.logprobs) {
                logprobs.push(value.logprobs)
              }
            } else if (value.type === 'response.reasoning_summary_part.added') {
              // the first reasoning start is pushed in isResponseOutputItemAddedReasoningChunk
              if (value.summary_index > 0) {
                const activeReasoningPart = activeReasoning[value.item_id]!

                activeReasoningPart.summaryParts[value.summary_index] = 'active'

                // since there is a new active summary part, we can conclude all can-conclude summary parts
                for (const summaryIndex of Object.keys(activeReasoningPart.summaryParts)) {
                  if (activeReasoningPart.summaryParts[summaryIndex] === 'can-conclude') {
                    controller.enqueue({
                      type: 'reasoning-end',
                      id: `${value.item_id}:${summaryIndex}`,
                      providerMetadata: {
                        [providerOptionsName]: {
                          itemId: value.item_id
                        } satisfies ResponsesReasoningProviderMetadata
                      }
                    })
                    activeReasoningPart.summaryParts[summaryIndex] = 'concluded'
                  }
                }

                controller.enqueue({
                  type: 'reasoning-start',
                  id: `${value.item_id}:${value.summary_index}`,
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item_id,
                      reasoningEncryptedContent: activeReasoning[value.item_id]?.encryptedContent ?? null
                    } satisfies ResponsesReasoningProviderMetadata
                  }
                })
              }
            } else if (value.type === 'response.reasoning_summary_text.delta') {
              controller.enqueue({
                type: 'reasoning-delta',
                id: `${value.item_id}:${value.summary_index}`,
                delta: value.delta,
                providerMetadata: {
                  [providerOptionsName]: {
                    itemId: value.item_id
                  } satisfies ResponsesReasoningProviderMetadata
                }
              })
            } else if (value.type === 'response.reasoning_summary_part.done') {
              // when the provider stores the message data, we can immediately conclude the reasoning part
              // since we do not need to send the encrypted content.
              if (store) {
                controller.enqueue({
                  type: 'reasoning-end',
                  id: `${value.item_id}:${value.summary_index}`,
                  providerMetadata: {
                    [providerOptionsName]: {
                      itemId: value.item_id
                    } satisfies ResponsesReasoningProviderMetadata
                  }
                })

                // mark the summary part as concluded
                activeReasoning[value.item_id]!.summaryParts[value.summary_index] = 'concluded'
              } else {
                // mark the summary part as can-conclude only
                // because we need to have a final summary part with the encrypted content
                activeReasoning[value.item_id]!.summaryParts[value.summary_index] = 'can-conclude'
              }
            } else if (isResponseFinishedChunk(value)) {
              finishReason = {
                unified: mapOpenResponsesFinishReason({
                  finishReason: value.response.incomplete_details?.reason,
                  hasFunctionCall
                }),
                raw: value.response.incomplete_details?.reason ?? undefined
              }
              usage = value.response.usage
              if (typeof value.response.service_tier === 'string') {
                serviceTier = value.response.service_tier
              }
            } else if (isResponseFailedChunk(value)) {
              const incompleteReason = value.response.incomplete_details?.reason
              finishReason = {
                unified: incompleteReason
                  ? mapOpenResponsesFinishReason({
                      finishReason: incompleteReason,
                      hasFunctionCall
                    })
                  : 'error',
                raw: incompleteReason ?? 'error'
              }
              usage = value.response.usage ?? undefined

              if (!encounteredStreamError && value.response.error != null) {
                encounteredStreamError = true
                controller.enqueue({
                  type: 'error',
                  error: {
                    type: 'response.failed',
                    sequence_number: value.sequence_number,
                    response: {
                      error: value.response.error,
                      incomplete_details: value.response.incomplete_details,
                      service_tier: value.response.service_tier
                    }
                  }
                })
              }
            } else if (isResponseAnnotationAddedChunk(value)) {
              ongoingAnnotations.push(value.annotation)
              if (value.annotation.type === 'url_citation') {
                controller.enqueue({
                  type: 'source',
                  sourceType: 'url',
                  id: createId(),
                  url: value.annotation.url,
                  title: value.annotation.title
                })
              } else if (value.annotation.type === 'file_citation') {
                controller.enqueue({
                  type: 'source',
                  sourceType: 'document',
                  id: createId(),
                  mediaType: 'text/plain',
                  title: value.annotation.filename,
                  filename: value.annotation.filename,
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: value.annotation.type,
                      fileId: value.annotation.file_id,
                      index: value.annotation.index
                    } satisfies Extract<ResponsesSourceDocumentProviderMetadata, { type: 'file_citation' }>
                  }
                })
              } else if (value.annotation.type === 'container_file_citation') {
                controller.enqueue({
                  type: 'source',
                  sourceType: 'document',
                  id: createId(),
                  mediaType: 'text/plain',
                  title: value.annotation.filename,
                  filename: value.annotation.filename,
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: value.annotation.type,
                      fileId: value.annotation.file_id,
                      containerId: value.annotation.container_id
                    } satisfies Extract<ResponsesSourceDocumentProviderMetadata, { type: 'container_file_citation' }>
                  }
                })
              } else if (value.annotation.type === 'file_path') {
                controller.enqueue({
                  type: 'source',
                  sourceType: 'document',
                  id: createId(),
                  mediaType: 'application/octet-stream',
                  title: value.annotation.file_id,
                  filename: value.annotation.file_id,
                  providerMetadata: {
                    [providerOptionsName]: {
                      type: value.annotation.type,
                      fileId: value.annotation.file_id,
                      index: value.annotation.index
                    } satisfies Extract<ResponsesSourceDocumentProviderMetadata, { type: 'file_path' }>
                  }
                })
              }
            } else if (isErrorChunk(value)) {
              encounteredStreamError = true
              finishReason = { unified: 'error', raw: 'error' }
              controller.enqueue({ type: 'error', error: value })
            }
          },

          flush(controller) {
            const providerMetadata: SharedProviderMetadata = {
              [providerOptionsName]: {
                responseId: responseId,
                ...(logprobs.length > 0 ? { logprobs } : {}),
                ...(serviceTier !== undefined ? { serviceTier } : {})
              } satisfies ResponsesProviderMetadata
            }

            controller.enqueue({
              type: 'finish',
              finishReason,
              usage: convertOpenResponsesUsage(usage),
              providerMetadata
            })
          }
        })
      ),
      request: { body },
      response: { headers: responseHeaders }
    }

    return result
  }
}

function isTextDeltaChunk(
  chunk: OpenResponsesChunk
): chunk is OpenResponsesChunk & { type: 'response.output_text.delta' } {
  return chunk.type === 'response.output_text.delta'
}

function isResponseOutputItemDoneChunk(
  chunk: OpenResponsesChunk
): chunk is OpenResponsesChunk & { type: 'response.output_item.done' } {
  return chunk.type === 'response.output_item.done'
}

function isResponseFinishedChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.completed' | 'response.incomplete'
} {
  return chunk.type === 'response.completed' || chunk.type === 'response.incomplete'
}

function isResponseFailedChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & { type: 'response.failed' } {
  return chunk.type === 'response.failed'
}

function isResponseCreatedChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & { type: 'response.created' } {
  return chunk.type === 'response.created'
}

function isResponseFunctionCallArgumentsDeltaChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.function_call_arguments.delta'
} {
  return chunk.type === 'response.function_call_arguments.delta'
}

function isResponseCustomToolCallInputDeltaChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.custom_tool_call_input.delta'
} {
  return chunk.type === 'response.custom_tool_call_input.delta'
}

function isResponseImageGenerationCallPartialImageChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.image_generation_call.partial_image'
} {
  return chunk.type === 'response.image_generation_call.partial_image'
}

function isResponseCodeInterpreterCallCodeDeltaChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.code_interpreter_call_code.delta'
} {
  return chunk.type === 'response.code_interpreter_call_code.delta'
}

function isResponseCodeInterpreterCallCodeDoneChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.code_interpreter_call_code.done'
} {
  return chunk.type === 'response.code_interpreter_call_code.done'
}

function isResponseApplyPatchCallOperationDiffDeltaChunk(
  chunk: OpenResponsesChunk
): chunk is OpenResponsesApplyPatchOperationDiffDeltaChunk {
  return chunk.type === 'response.apply_patch_call_operation_diff.delta'
}

function isResponseApplyPatchCallOperationDiffDoneChunk(
  chunk: OpenResponsesChunk
): chunk is OpenResponsesApplyPatchOperationDiffDoneChunk {
  return chunk.type === 'response.apply_patch_call_operation_diff.done'
}

function isResponseOutputItemAddedChunk(
  chunk: OpenResponsesChunk
): chunk is OpenResponsesChunk & { type: 'response.output_item.added' } {
  return chunk.type === 'response.output_item.added'
}

function isResponseAnnotationAddedChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & {
  type: 'response.output_text.annotation.added'
} {
  return chunk.type === 'response.output_text.annotation.added'
}

function isErrorChunk(chunk: OpenResponsesChunk): chunk is OpenResponsesChunk & { type: 'error' } {
  return chunk.type === 'error'
}

function isResponseOutputChunk(chunk: OpenResponsesChunk): boolean {
  return !(
    chunk.type === 'response.created' ||
    chunk.type === 'response.failed' ||
    chunk.type === 'error' ||
    chunk.type === 'unknown_chunk'
  )
}

function mapWebSearchOutput(action: OpenResponsesWebSearchAction | null | undefined): WebSearchOutput {
  if (action == null) {
    return {}
  }

  switch (action.type) {
    case 'search':
      return {
        action: {
          type: 'search',
          query: action.query ?? undefined,
          ...(action.queries != null && { queries: action.queries })
        },
        // include sources when provided by the Responses API (behind include flag)
        ...(action.sources != null && { sources: action.sources })
      }
    case 'open_page':
      return { action: { type: 'openPage', url: action.url } }
    case 'find_in_page':
      return {
        action: {
          type: 'findInPage',
          url: action.url,
          pattern: action.pattern
        }
      }
  }
}

// The delta is embedded in a JSON string.
// To escape it, we use JSON.stringify and slice to remove the outer quotes.
function escapeJSONDelta(delta: string) {
  return JSON.stringify(delta).slice(1, -1)
}
