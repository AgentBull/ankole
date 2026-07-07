import { safeJsonParse, type JsonObject } from '@pleisto/active-support'
import { z } from 'zod'
import { errorMessage } from '../../common/errors'

export function zodToJSONSchema(schema: z.ZodType): JsonObject {
  return z.toJSONSchema(schema) as JsonObject
}

export function validateToolArguments(args: string, schema: z.ZodType): unknown {
  const decoded = safeJsonParse(args).match(
    value => value,
    error => {
      throw new Error(`tool arguments must be valid JSON: ${errorMessage(error)}`)
    }
  )

  return schema.parse(decoded)
}
