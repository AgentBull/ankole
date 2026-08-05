import { Buffer } from 'node:buffer'
import { safeJsonParse as safeJSONParse, type JsonObject as JSONObject } from '@agentbull/active-support'
import { z } from 'zod'
import { errorMessage } from '../../common/errors'

export const MAX_TOOL_ARGUMENT_BYTES = 256 * 1024
export const MAX_REPAIRABLE_TOOL_ARGUMENT_BYTES = 64 * 1024

export type ToolArgumentRepair = 'none' | 'code_fence' | 'balanced_object' | 'incomplete_container'

export interface ValidatedToolArguments {
  value: unknown
  normalizedArguments: string
  repair: ToolArgumentRepair
}

export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
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

export function validateToolArguments(args: string, schema: z.ZodType): unknown {
  return validateToolArgumentsWithRepair(args, schema).value
}

/**
 * Parses model-generated arguments through a bounded, deterministic repair ladder.
 *
 * Repairs may recover transport punctuation, but schema validation still owns the
 * tool's semantic contract. An unterminated string is deliberately not repaired:
 * its missing suffix may contain user-visible content or an unsafe action.
 */
export function validateToolArgumentsWithRepair(args: string, schema: z.ZodType): ValidatedToolArguments {
  const argumentBytes = Buffer.byteLength(args, 'utf8')
  if (argumentBytes > MAX_TOOL_ARGUMENT_BYTES) {
    throw new Error(`tool arguments exceed the ${MAX_TOOL_ARGUMENT_BYTES}-byte limit`)
  }

  const strict = parseJSON(args)
  if (strict.ok) return validatedToolArguments(strict.value, args, 'none', schema)

  if (argumentBytes <= MAX_REPAIRABLE_TOOL_ARGUMENT_BYTES) {
    const base = stripJSONCodeFence(args) ?? args.trim()
    const candidates: Array<[ToolArgumentRepair, string | undefined]> = [
      ['code_fence', base === args.trim() ? undefined : base],
      ['balanced_object', extractBalancedJSONObject(base)],
      ['incomplete_container', repairIncompleteJSONObject(base)]
    ]
    const seen = new Set<string>([args])

    for (const [repair, candidate] of candidates) {
      if (!candidate || seen.has(candidate)) continue
      seen.add(candidate)
      const parsed = parseJSON(candidate)
      if (parsed.ok) return validatedToolArguments(parsed.value, candidate, repair, schema)
    }
  }

  throw new Error(`tool arguments must be valid JSON: ${errorMessage(strict.error)}`)
}

function validatedToolArguments(
  decoded: unknown,
  normalizedArguments: string,
  repair: ToolArgumentRepair,
  schema: z.ZodType
): ValidatedToolArguments {
  const value = schema.parse(decoded)
  return {
    value,
    normalizedArguments: repair === 'none' ? normalizedArguments : JSON.stringify(decoded),
    repair
  }
}

function parseJSON(input: string): { ok: true; value: unknown } | { ok: false; error: unknown } {
  const parsed = safeJSONParse(input)
  if (parsed.isErr()) return { ok: false, error: parsed.error }
  return { ok: true, value: parsed.value }
}

function stripJSONCodeFence(input: string): string | undefined {
  const trimmed = input.trim()
  const match = /^```(?:json)?\s*\n?([\s\S]*?)\n?```$/i.exec(trimmed)
  return match?.[1]?.trim()
}

/** Returns the first complete JSON object while ignoring prefix/suffix chatter. */
function extractBalancedJSONObject(input: string): string | undefined {
  const start = input.indexOf('{')
  if (start < 0) return undefined

  const stack: string[] = []
  let inString = false
  let escaped = false

  for (let index = start; index < input.length; index++) {
    const char = input[index]!
    if (inString) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === '"') inString = false
      continue
    }

    if (char === '"') {
      inString = true
      continue
    }
    if (char === '{') stack.push('}')
    else if (char === '[') stack.push(']')
    else if (char === '}' || char === ']') {
      if (stack.pop() !== char) return undefined
      if (stack.length === 0) return input.slice(start, index + 1)
    }
  }
}

/**
 * Closes unmatched object/array containers and removes dangling commas only
 * when the stream stopped outside a JSON string.
 */
function repairIncompleteJSONObject(input: string): string | undefined {
  const trimmed = input.trim()
  if (!trimmed.startsWith('{')) return undefined

  const stack: string[] = []
  let inString = false
  let escaped = false
  let repaired = ''

  for (const char of trimmed) {
    if (inString) {
      if (escaped) {
        repaired += char
        escaped = false
      } else if (char === '\\') {
        repaired += char
        escaped = true
      } else if (char === '"') {
        repaired += char
        inString = false
      } else if (char === '\n') repaired += '\\n'
      else if (char === '\r') repaired += '\\r'
      else if (char === '\t') repaired += '\\t'
      else repaired += char
      continue
    }

    if (char === '"') {
      repaired += char
      inString = true
    } else if (char === '{') {
      repaired += char
      stack.push('}')
    } else if (char === '[') {
      repaired += char
      stack.push(']')
    } else if (char === '}' || char === ']') {
      if (stack.pop() !== char) return undefined
      repaired += char
    } else {
      repaired += char
    }
  }

  if (inString || escaped) return undefined
  if (stack.length > 0) repaired += [...stack].reverse().join('')
  return removeTrailingJSONCommas(repaired)
}

function removeTrailingJSONCommas(input: string): string {
  let output = ''
  let inString = false
  let escaped = false

  for (let index = 0; index < input.length; index++) {
    const char = input[index]!
    if (inString) {
      output += char
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === '"') inString = false
      continue
    }

    if (char === '"') {
      output += char
      inString = true
      continue
    }

    if (char === ',') {
      let lookahead = index + 1
      while (/\s/.test(input[lookahead] ?? '')) lookahead += 1
      if (input[lookahead] === '}' || input[lookahead] === ']') continue
    }

    output += char
  }

  return output
}
