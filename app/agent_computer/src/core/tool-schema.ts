import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { z } from 'zod'

export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = cleanedJSONSchema(schema)
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
  return jsonSchema
}

function cleanedJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  delete jsonSchema.$schema
  removeSafeIntegerBounds(jsonSchema)
  return jsonSchema
}

/**
 * Deletes the JS safe-integer bounds that `z.number().int()` emits. The zod
 * validator still enforces them at execution; in the model-visible schema they
 * are runtime artifacts, not part of the tool contract.
 */
function removeSafeIntegerBounds(node: unknown): void {
  if (Array.isArray(node)) {
    for (const item of node) removeSafeIntegerBounds(item)
    return
  }
  if (!node || typeof node !== 'object') return

  const record = node as Record<string, unknown>
  if (record.maximum === Number.MAX_SAFE_INTEGER) delete record.maximum
  if (record.minimum === -Number.MAX_SAFE_INTEGER) delete record.minimum
  for (const value of Object.values(record)) removeSafeIntegerBounds(value)
}
