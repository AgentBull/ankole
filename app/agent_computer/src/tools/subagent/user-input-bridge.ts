import { jsonObject, type JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { zodToJSONSchema } from '../../core/llm/tool-schema'
import type { DynamicToolCallParams } from './generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolSpec } from './generated/protocol/v2/DynamicToolSpec'
import type { JsonValue as JSONValue } from './generated/protocol/serde_json/JsonValue'

export const SUBAGENT_USER_INPUT_TOOL_NAME = 'request_parent_input'

const UserInputArguments = z
  .object({
    questions: z
      .array(
        z
          .object({
            id: z.string().min(1).max(64),
            header: z.string().min(1).max(64),
            question: z.string().min(1).max(2_000),
            isOther: z.boolean().optional(),
            isSecret: z.boolean().optional(),
            options: z
              .array(
                z
                  .object({
                    label: z.string().min(1).max(200),
                    description: z.string().min(1).max(1_000)
                  })
                  .strict()
              )
              .max(3)
              .nullable()
              .optional()
          })
          .strict()
      )
      .min(1)
      .max(3)
  })
  .strict()

export function subagentUserInputToolSpec(): DynamicToolSpec {
  return {
    type: 'function',
    name: SUBAGENT_USER_INPUT_TOOL_NAME,
    description:
      'Pause this background task and ask the parent agent for information that is genuinely required to continue. Use this instead of request_user_input, which is unavailable in Default mode. Ask one to three concise questions.',
    inputSchema: zodToJSONSchema(UserInputArguments) as unknown as JSONValue
  }
}

export function pendingUserInputFromDynamicTool(params: DynamicToolCallParams): JSONObject | undefined {
  if (params.tool !== SUBAGENT_USER_INPUT_TOOL_NAME) return undefined
  const parsed = UserInputArguments.safeParse(params.arguments)
  if (!parsed.success) return undefined

  return jsonObject({
    threadId: params.threadId,
    turnId: params.turnId,
    itemId: params.callId,
    autoResolutionMs: null,
    questions: parsed.data.questions.map(question => ({
      id: question.id,
      header: question.header,
      question: question.question,
      isOther: question.isOther ?? true,
      isSecret: question.isSecret ?? false,
      options: question.options ?? null
    }))
  })
}
