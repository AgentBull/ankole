import { safeJsonParse as safeJSONParse, type JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { errorMessage } from '../../common/errors'

export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
  return jsonSchema
}

export function validateToolArguments(args: string, schema: z.ZodType): unknown {
  const decoded = safeJSONParse(args).match(
    value => value,
    error => {
      throw new Error(`tool arguments must be valid JSON: ${errorMessage(error)}`)
    }
  )

  return schema.parse(decoded)
}
