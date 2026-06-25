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

/**
 * One-shot (non-streaming) BullX call: maps the BullX context onto an AI SDK generateText
 * request, runs it, and folds the result back into a durable AssistantMessage.
 *
 * This NEVER throws. Every outcome — missing model instance, provider error, caller abort —
 * is returned as an assistant message with the matching stop reason, so the agent runtime can
 * persist the turn and recover instead of unwinding the loop. The streaming counterpart lives
 * elsewhere; this is the wrapper used for single-response generations.
 */
export async function generateBullXText(
  model: Model<any>,
  context: Context,
  options: SimpleStreamOptions = {}
): Promise<AssistantMessage> {
  // A catalog Model without a resolved sdkModel (no API key / base URL bound yet) can't be
  // called — surface that as an error turn rather than dereferencing undefined.
  if (!model.sdkModel) {
    return createBullXAssistantMessage(model, 'error', [], {
      errorMessage: `LLM model ${model.provider}/${model.id} is missing an AI SDK model instance`
    })
  }

  try {
    // Treat 0 / negative / non-number as "no cap" so a bad option doesn't request zero tokens.
    const maxOutputTokens =
      typeof options.maxTokens === 'number' && options.maxTokens > 0 ? options.maxTokens : undefined
    const result = await generateText({
      model: model.sdkModel,
      system: context.systemPrompt,
      messages: convertBullXMessagesToModelMessages(context.messages),
      maxOutputTokens,
      temperature: options.temperature,
      // Drops the reasoning request on non-reasoning models so we don't send an unsupported option.
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
      // generateText returns the text already joined; wrap it as a single text block (empty -> no blocks).
      result.text ? [{ type: 'text', text: result.text }] : [],
      {
        responseId: result.response.id,
        responseModel: result.response.modelId,
        usage: toBullXUsage(result.usage, model)
      }
    )
  } catch (error) {
    // Distinguish a caller-initiated cancel ('aborted') from a genuine failure ('error') so the
    // runtime can tell intentional stops apart from things worth retrying/alerting on.
    return createBullXAssistantMessage(model, options.signal?.aborted ? 'aborted' : 'error', [], {
      errorMessage: error instanceof Error ? error.message : String(error)
    })
  }
}
