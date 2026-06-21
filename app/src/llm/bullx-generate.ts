import { generateText } from './generate-text'
import type { AssistantMessage, Context, Model, SimpleStreamOptions } from './bullx'
import {
  convertBullXMessagesToModelMessages,
  createBullXAssistantMessage,
  createBullXProviderOptions,
  resolveBullXReasoning,
  toBullXStopReason,
  toBullXUsage
} from './bullx-ai-sdk'

/** Runs a non-streaming BullX LLM call through the AI SDK and returns the durable assistant message shape. */
export async function generateBullXText(
  model: Model<any>,
  context: Context,
  options: SimpleStreamOptions = {}
): Promise<AssistantMessage> {
  if (!model.sdkModel) {
    return createBullXAssistantMessage(model, 'error', [], {
      errorMessage: `LLM model ${model.provider}/${model.id} is missing an AI SDK model instance`
    })
  }

  try {
    const maxOutputTokens =
      typeof options.maxTokens === 'number' && options.maxTokens > 0 ? options.maxTokens : undefined
    const result = await generateText({
      model: model.sdkModel,
      system: context.systemPrompt,
      messages: convertBullXMessagesToModelMessages(context.messages),
      maxOutputTokens,
      temperature: options.temperature,
      reasoning: resolveBullXReasoning(model, options),
      maxRetries: options.maxRetries,
      timeout: options.timeoutMs,
      headers: options.headers,
      abortSignal: options.signal,
      providerOptions: createBullXProviderOptions(model, options)
    })
    return createBullXAssistantMessage(
      model,
      toBullXStopReason(result.finishReason),
      result.text ? [{ type: 'text', text: result.text }] : [],
      {
        responseId: result.response.id,
        responseModel: result.response.modelId,
        usage: toBullXUsage(result.usage, model)
      }
    )
  } catch (error) {
    return createBullXAssistantMessage(model, options.signal?.aborted ? 'aborted' : 'error', [], {
      errorMessage: error instanceof Error ? error.message : String(error)
    })
  }
}
