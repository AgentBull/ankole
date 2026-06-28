import {
  UnsupportedFunctionalityError,
  type LanguageModelPrompt,
  type SharedWarning
} from '@/ai-gateway-client/provider'
import {
  convertToBase64,
  getTopLevelMediaType,
  isNonNullable,
  parseProviderOptions,
  resolveFullMediaType,
  resolveProviderReference,
  type ToolNameMapping
} from '@/ai-gateway-client/provider-utils'
import { z } from 'zod/v4'
import type {
  OpenResponsesCompactionItem,
  OpenResponsesFunctionCallOutput,
  OpenResponsesInput,
  OpenResponsesReasoning
} from './open-responses-api'

function serializeToolCallArguments(input: unknown): string {
  return JSON.stringify(input === undefined ? {} : input)
}

export async function convertToOpenResponsesInput({
  prompt,
  toolNameMapping,
  systemMessageMode,
  providerOptionsName,
  passThroughUnsupportedFiles = false,
  store,
  hasConversation = false,
  hasPreviousResponseId = false
}: {
  prompt: LanguageModelPrompt
  toolNameMapping: ToolNameMapping
  systemMessageMode: 'system' | 'developer' | 'remove'
  providerOptionsName: string
  passThroughUnsupportedFiles?: boolean
  store: boolean
  hasConversation?: boolean // when true, skip assistant messages that already have item IDs
  hasPreviousResponseId?: boolean // when true, skip reasoning and function-call items that already exist in the previous response chain
}): Promise<{
  input: OpenResponsesInput
  warnings: Array<SharedWarning>
}> {
  let input: OpenResponsesInput = []
  const warnings: Array<SharedWarning> = []

  for (const { role, content } of prompt) {
    switch (role) {
      case 'system': {
        switch (systemMessageMode) {
          case 'system': {
            input.push({ role: 'system', content })
            break
          }
          case 'developer': {
            input.push({ role: 'developer', content })
            break
          }
          case 'remove': {
            warnings.push({
              type: 'other',
              message: 'system messages are removed for this model'
            })
            break
          }
          default: {
            const _exhaustiveCheck: never = systemMessageMode
            throw new Error(`Unsupported system message mode: ${_exhaustiveCheck}`)
          }
        }
        break
      }

      case 'user': {
        input.push({
          role: 'user',
          content: content.map((part, index) => {
            switch (part.type) {
              case 'text': {
                return { type: 'input_text', text: part.text }
              }
              case 'file': {
                switch (part.data.type) {
                  case 'reference': {
                    const fileId = resolveProviderReference({
                      reference: part.data.reference,
                      provider: providerOptionsName
                    })

                    if (getTopLevelMediaType(part.mediaType) === 'image') {
                      return {
                        type: 'input_image',
                        file_id: fileId,
                        detail: part.providerOptions?.[providerOptionsName]?.imageDetail
                      }
                    }

                    return {
                      type: 'input_file',
                      file_id: fileId
                    }
                  }
                  case 'text': {
                    throw new UnsupportedFunctionalityError({
                      functionality: 'text file parts'
                    })
                  }
                  case 'url':
                  case 'data': {
                    const topLevel = getTopLevelMediaType(part.mediaType)

                    if (topLevel === 'image') {
                      return {
                        type: 'input_image',
                        ...(part.data.type === 'url'
                          ? { image_url: part.data.url.toString() }
                          : typeof part.data.data === 'string'
                            ? { file_id: part.data.data }
                            : {
                                image_url: `data:${resolveFullMediaType({ part })};base64,${convertToBase64(part.data.data)}`
                              }),
                        detail: part.providerOptions?.[providerOptionsName]?.imageDetail
                      }
                    } else {
                      if (part.data.type === 'url') {
                        return {
                          type: 'input_file',
                          file_url: part.data.url.toString()
                        }
                      }

                      const fullMediaType = resolveFullMediaType({ part })
                      if (fullMediaType !== 'application/pdf' && !passThroughUnsupportedFiles) {
                        throw new UnsupportedFunctionalityError({
                          functionality: `file part media type ${fullMediaType}`
                        })
                      }

                      return {
                        type: 'input_file',
                        ...(typeof part.data.data === 'string'
                          ? { file_id: part.data.data }
                          : {
                              filename:
                                part.filename ??
                                (fullMediaType === 'application/pdf' ? `part-${index}.pdf` : `part-${index}`),
                              file_data: `data:${fullMediaType};base64,${convertToBase64(part.data.data)}`
                            })
                      }
                    }
                  }
                }
              }
            }
          })
        })

        break
      }

      case 'assistant': {
        const reasoningMessages: Record<string, OpenResponsesReasoning> = {}

        for (const part of content) {
          switch (part.type) {
            case 'text': {
              const providerOptions = part.providerOptions?.[providerOptionsName]
              const id = providerOptions?.itemId as string | undefined
              const phase = providerOptions?.phase as 'commentary' | 'final_answer' | null | undefined

              // when using conversation, skip items that already exist in the conversation context to avoid "Duplicate item found" errors
              if (hasConversation && id != null) {
                break
              }

              // item references reduce the payload size
              if (store && id != null) {
                input.push({ type: 'item_reference', id })
                break
              }

              input.push({
                role: 'assistant',
                content: [{ type: 'output_text', text: part.text }],
                id,
                ...(phase != null && { phase })
              })

              break
            }
            case 'tool-call': {
              const id = (part.providerOptions?.[providerOptionsName]?.itemId ??
                (
                  part as {
                    providerMetadata?: {
                      [providerOptionsName]?: { itemId?: string }
                    }
                  }
                ).providerMetadata?.[providerOptionsName]?.itemId) as string | undefined

              const namespace = (part.providerOptions?.[providerOptionsName]?.namespace ??
                (
                  part as {
                    providerMetadata?: {
                      [providerOptionsName]?: { namespace?: string }
                    }
                  }
                ).providerMetadata?.[providerOptionsName]?.namespace) as string | undefined

              if (hasConversation && id != null) {
                break
              }

              const resolvedToolName = toolNameMapping.toProviderToolName(part.toolName)

              if (part.providerExecuted) {
                if (store && id != null) {
                  input.push({ type: 'item_reference', id })
                }
                break
              }

              // When chaining with a previous response id, items already part
              // of that response chain must not be resent.
              if (hasPreviousResponseId && store && id != null) {
                break
              }

              input.push({
                type: 'function_call',
                call_id: part.toolCallId,
                name: resolvedToolName,
                arguments: serializeToolCallArguments(part.input),
                ...(namespace != null && { namespace })
              })
              break
            }

            // assistant tool result parts are from provider-executed tools:
            case 'tool-result': {
              // Skip execution-denied results - these are synthetic results from denied
              // approvals and have no corresponding item in the provider store.
              // Check both the direct type and if it was transformed to json with execution-denied inside
              if (
                part.output.type === 'execution-denied' ||
                (part.output.type === 'json' &&
                  typeof part.output.value === 'object' &&
                  part.output.value != null &&
                  'type' in part.output.value &&
                  part.output.value.type === 'execution-denied')
              ) {
                break
              }

              if (hasConversation) {
                break
              }

              if (store) {
                const itemId =
                  (part.providerOptions?.[providerOptionsName] as { itemId?: string } | undefined)?.itemId ??
                  part.toolCallId
                input.push({ type: 'item_reference', id: itemId })
              } else {
                warnings.push({
                  type: 'other',
                  message: `Results for provider-executed tool ${part.toolName} are not sent to the API when store is false`
                })
              }

              break
            }

            case 'reasoning': {
              const providerOptions = await parseProviderOptions({
                provider: providerOptionsName,
                providerOptions: part.providerOptions,
                schema: openResponsesReasoningProviderOptionsSchema
              })

              const reasoningId = providerOptions?.itemId

              if ((hasConversation || hasPreviousResponseId) && reasoningId != null) {
                break
              }

              if (reasoningId != null) {
                const reasoningMessage = reasoningMessages[reasoningId]

                if (store) {
                  // use item references to refer to reasoning (single reference)
                  // when the first part is encountered
                  if (reasoningMessage === undefined) {
                    input.push({ type: 'item_reference', id: reasoningId })

                    // store unused reasoning message to mark id as used
                    reasoningMessages[reasoningId] = {
                      type: 'reasoning',
                      id: reasoningId,
                      summary: []
                    }
                  }
                } else {
                  const summaryParts: Array<{
                    type: 'summary_text'
                    text: string
                  }> = []

                  if (part.text.length > 0) {
                    summaryParts.push({
                      type: 'summary_text',
                      text: part.text
                    })
                  } else if (reasoningMessage !== undefined) {
                    warnings.push({
                      type: 'other',
                      message: `Cannot append empty reasoning part to existing reasoning sequence. Skipping reasoning part: ${JSON.stringify(part)}.`
                    })
                  }

                  if (reasoningMessage === undefined) {
                    reasoningMessages[reasoningId] = {
                      type: 'reasoning',
                      id: reasoningId,
                      encrypted_content: providerOptions?.reasoningEncryptedContent,
                      summary: summaryParts
                    }
                    input.push(reasoningMessages[reasoningId])
                  } else {
                    reasoningMessage.summary.push(...summaryParts)

                    // updated encrypted content to enable setting it in the last summary part:
                    if (providerOptions?.reasoningEncryptedContent != null) {
                      reasoningMessage.encrypted_content = providerOptions.reasoningEncryptedContent
                    }
                  }
                }
              } else {
                // No itemId — fall back to encrypted_content if available.
                // The OpenResponses API accepts reasoning items without an
                // id when encrypted_content is provided, enabling multi-turn
                // reasoning even when server-side item persistence is not used
                // or when itemId has been stripped from providerOptions.
                const encryptedContent = providerOptions?.reasoningEncryptedContent

                if (encryptedContent != null) {
                  const summaryParts: Array<{
                    type: 'summary_text'
                    text: string
                  }> = []
                  if (part.text.length > 0) {
                    summaryParts.push({
                      type: 'summary_text',
                      text: part.text
                    })
                  }
                  input.push({
                    type: 'reasoning',
                    encrypted_content: encryptedContent,
                    summary: summaryParts
                  })
                } else {
                  warnings.push({
                    type: 'other',
                    message: `Non-OpenResponses reasoning parts are not supported. Skipping reasoning part: ${JSON.stringify(part)}.`
                  })
                }
              }
              break
            }

            case 'custom': {
              if (part.kind === 'openai.compaction') {
                const providerOptions = part.providerOptions?.[providerOptionsName]
                const id = providerOptions?.itemId as string | undefined

                if (hasConversation && id != null) {
                  break
                }

                if (store && id != null) {
                  input.push({ type: 'item_reference', id })
                  break
                }

                const encryptedContent = providerOptions?.encryptedContent as string | undefined

                if (id != null) {
                  input.push({
                    type: 'compaction',
                    id,
                    encrypted_content: encryptedContent!
                  } satisfies OpenResponsesCompactionItem)
                }
              }
              break
            }
          }
        }

        break
      }

      case 'tool': {
        for (const part of content) {
          if (part.type === 'tool-approval-response') {
            warnings.push({
              type: 'unsupported',
              feature: 'provider tool approval response'
            })
            continue
          }

          const output = part.output

          // Skip execution-denied with approvalId - already handled via tool-approval-response
          if (output.type === 'execution-denied') {
            const approvalId = (output.providerOptions?.openai as { approvalId?: string })?.approvalId

            if (approvalId) {
              continue
            }
          }

          let contentValue: OpenResponsesFunctionCallOutput['output']
          switch (output.type) {
            case 'text':
            case 'error-text':
              contentValue = output.value
              break
            case 'execution-denied':
              contentValue = output.reason ?? 'Tool call execution denied.'
              break
            case 'json':
            case 'error-json':
              contentValue = JSON.stringify(output.value)
              break
            case 'content':
              contentValue = output.value
                .map(item => {
                  switch (item.type) {
                    case 'text': {
                      return { type: 'input_text' as const, text: item.text }
                    }

                    case 'file': {
                      const topLevel = getTopLevelMediaType(item.mediaType)
                      const imageDetail = item.providerOptions?.[providerOptionsName]?.imageDetail

                      if (item.data.type === 'data') {
                        const fullMediaType = resolveFullMediaType({
                          part: item
                        })
                        if (topLevel === 'image') {
                          return {
                            type: 'input_image' as const,
                            image_url: `data:${fullMediaType};base64,${convertToBase64(item.data.data)}`,
                            detail: imageDetail
                          }
                        }
                        return {
                          type: 'input_file' as const,
                          filename: item.filename ?? 'data',
                          file_data: `data:${fullMediaType};base64,${convertToBase64(item.data.data)}`
                        }
                      }

                      if (item.data.type === 'url') {
                        if (topLevel === 'image') {
                          return {
                            type: 'input_image' as const,
                            image_url: item.data.url.toString(),
                            detail: imageDetail
                          }
                        }
                        return {
                          type: 'input_file' as const,
                          file_url: item.data.url.toString()
                        }
                      }

                      warnings.push({
                        type: 'other',
                        message: `unsupported tool content part type: ${item.type} with data type: ${item.data.type}`
                      })
                      return undefined
                    }

                    default: {
                      warnings.push({
                        type: 'other',
                        message: `unsupported tool content part type: ${item.type}`
                      })
                      return undefined
                    }
                  }
                })
                .filter(isNonNullable)
              break
          }

          input.push({
            type: 'function_call_output',
            call_id: part.toolCallId,
            output: contentValue
          })
        }

        break
      }

      default: {
        const _exhaustiveCheck: never = role
        throw new Error(`Unsupported role: ${_exhaustiveCheck}`)
      }
    }
  }

  // when store is false, remove reasoning parts without encrypted content
  if (!store && input.some(item => 'type' in item && item.type === 'reasoning' && item.encrypted_content == null)) {
    warnings.push({
      type: 'other',
      message:
        'Reasoning parts without encrypted content are not supported when store is false. Skipping reasoning parts.'
    })
    input = input.filter(item => !('type' in item) || item.type !== 'reasoning' || item.encrypted_content != null)
  }

  return { input, warnings }
}

const openResponsesReasoningProviderOptionsSchema = z.object({
  itemId: z.string().nullish(),
  reasoningEncryptedContent: z.string().nullish()
})

export type OpenResponsesReasoningProviderOptions = z.infer<typeof openResponsesReasoningProviderOptionsSchema>
