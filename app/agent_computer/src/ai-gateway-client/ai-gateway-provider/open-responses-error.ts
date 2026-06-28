import { z } from 'zod/v4'
import { createJsonErrorResponseHandler } from '@/ai-gateway-client/provider-utils'

export const openResponsesErrorDataSchema = z.object({
  error: z.object({
    message: z.string(),

    // The additional information below is handled loosely to support
    // OpenResponses-compatible providers that have slightly different error
    // responses:
    type: z.string().nullish(),
    param: z.any().nullish(),
    code: z.union([z.string(), z.number()]).nullish()
  })
})

export type OpenResponsesErrorData = z.infer<typeof openResponsesErrorDataSchema>

export const openResponsesFailedResponseHandler = createJsonErrorResponseHandler({
  errorSchema: openResponsesErrorDataSchema,
  errorToMessage: data => data.error.message
})
