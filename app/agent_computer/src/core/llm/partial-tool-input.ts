/**
 * Reads a tool call's JSON argument object that may stop part way through.
 *
 * The model writes tool arguments as one JSON object. When a response reaches
 * its output-token limit while that object is still being written, the object
 * arrives unterminated and the call cannot run. `tool-schema.ts` owns the
 * separate question of whether arguments are executable, and deliberately
 * refuses to repair an unterminated string, because the missing suffix can hold
 * user-visible content or an unsafe action. This module answers the other
 * question: how far did the model get before it stopped. It never produces
 * executable arguments.
 *
 * A scan reads the complete input once, in O(n). Fields that completed before
 * the stopping point are parsed with `JSON.parse`. A second scan can decode one
 * named string field to count the characters of it that arrived.
 */

import { recordValue, safeJsonParse as safeJSONParse } from '@agentbull/active-support'

/** Decoded forms of the JSON escapes that stand for one character. */
const SIMPLE_ESCAPES: Record<string, string | undefined> = {
  '"': '"',
  '\\': '\\',
  '/': '/',
  b: '\b',
  f: '\f',
  n: '\n',
  r: '\r',
  t: '\t'
}

type Phase =
  | 'initial' // before the opening brace
  | 'expectKey' // after the opening brace or a comma
  | 'inKey' // inside a key string
  | 'expectColon' // after a key string
  | 'expectValue' // after a colon
  | 'inStringValue' // inside a string value that is not decoded
  | 'inOtherValue' // inside a non-string value, tracking container depth
  | 'streaming' // decoding the named field's string value
  | 'afterValue' // after a complete value
  | 'done' // the object closed, or the named field completed
  | 'failed' // the input is not a JSON object

function isJSONWhitespace(character: string): boolean {
  return character === ' ' || character === '\t' || character === '\n' || character === '\r'
}

interface ToolInputScan {
  /** Whether the object closed, or the named field completed. */
  complete: boolean
  /** Whether the input is not a JSON object this scan can read. */
  failed: boolean
  /** Fields that completed before the stopping point. */
  completedFields: Record<string, unknown>
  /** Name of the field whose value the input stopped inside, if any. */
  pendingField?: string
  /** Decoded characters of the named string field that arrived. */
  streamingChars: number
}

/**
 * Scans the raw argument text once and reports what completed before the input
 * ran out. When `streamingField` names a string field, the scan decodes that
 * field's value to count the characters that arrived. An escape sequence that
 * the input ends inside is not counted.
 */
function scanToolInput(input: string, streamingField?: string): ToolInputScan {
  let pos = 0
  let phase: Phase = 'initial'
  let key = ''
  let field: string | undefined
  let valueDepth = 0
  let valueInString = false
  let streamingChars = 0

  // End of the prefix that holds only completed fields. It advances to every
  // point at which the object could be closed, so the result can parse
  // `input.slice(0, boundary)` with a closing brace appended.
  let boundary = 0

  const enterExpectKey = (): Phase => {
    boundary = pos
    field = undefined
    return 'expectKey'
  }

  const enterAfterValue = (): Phase => {
    boundary = pos
    field = undefined
    return 'afterValue'
  }

  // Decodes one escape sequence at the cursor. `incomplete` means the input
  // ends inside the sequence; `invalid` means the sequence is not JSON.
  const readEscape = (): { char: string } | 'incomplete' | 'invalid' => {
    if (pos + 1 >= input.length) return 'incomplete'
    const marker = input[pos + 1]
    if (marker === 'u') {
      if (pos + 6 > input.length) return 'incomplete'
      const hex = input.slice(pos + 2, pos + 6)
      if (!/^[0-9a-fA-F]{4}$/.test(hex)) return 'invalid'
      pos += 6
      return { char: String.fromCharCode(parseInt(hex, 16)) }
    }
    const simple = SIMPLE_ESCAPES[marker]
    if (simple === undefined) return 'invalid'
    pos += 2
    return { char: simple }
  }

  scan: while (pos < input.length) {
    const character = input[pos]

    switch (phase) {
      case 'initial':
        if (isJSONWhitespace(character)) {
          pos += 1
          break
        }
        if (character !== '{') {
          phase = 'failed'
          break scan
        }
        pos += 1
        phase = enterExpectKey()
        break

      case 'expectKey':
        if (isJSONWhitespace(character)) {
          pos += 1
          break
        }
        if (character === '}') {
          pos += 1
          phase = 'done'
          break scan
        }
        if (character !== '"') {
          phase = 'failed'
          break scan
        }
        key = ''
        pos += 1
        phase = 'inKey'
        break

      case 'inKey': {
        if (character === '\\') {
          const decoded = readEscape()
          if (decoded === 'invalid') {
            phase = 'failed'
            break scan
          }
          if (decoded === 'incomplete') break scan
          key += decoded.char
          break
        }
        if (character === '"') {
          pos += 1
          phase = 'expectColon'
          break
        }
        key += character
        pos += 1
        break
      }

      case 'expectColon':
        if (isJSONWhitespace(character)) {
          pos += 1
          break
        }
        if (character !== ':') {
          phase = 'failed'
          break scan
        }
        pos += 1
        field = key
        phase = 'expectValue'
        break

      case 'expectValue':
        if (isJSONWhitespace(character)) {
          pos += 1
          break
        }
        if (field === streamingField) {
          if (character !== '"') {
            phase = 'failed'
            break scan
          }
          pos += 1
          phase = 'streaming'
          break
        }
        if (character === '"') {
          pos += 1
          phase = 'inStringValue'
          break
        }
        valueDepth = character === '{' || character === '[' ? 1 : 0
        valueInString = false
        pos += 1
        phase = 'inOtherValue'
        break

      case 'inStringValue':
        if (character === '\\') {
          if (pos + 1 >= input.length) break scan
          pos += 2
          break
        }
        if (character === '"') {
          pos += 1
          phase = enterAfterValue()
          break
        }
        pos += 1
        break

      case 'inOtherValue':
        if (valueInString) {
          if (character === '\\') {
            if (pos + 1 >= input.length) break scan
            pos += 2
            break
          }
          if (character === '"') valueInString = false
          pos += 1
          break
        }
        if (character === '"') {
          valueInString = true
          pos += 1
          break
        }
        if (character === '{' || character === '[') {
          valueDepth += 1
          pos += 1
          break
        }
        if (character === '}' || character === ']') {
          if (valueDepth === 0) {
            // A scalar ended: this character belongs to the enclosing object.
            phase = enterAfterValue()
            break
          }
          valueDepth -= 1
          pos += 1
          if (valueDepth === 0) phase = enterAfterValue()
          break
        }
        if (valueDepth === 0 && (character === ',' || isJSONWhitespace(character))) {
          phase = enterAfterValue()
          break
        }
        pos += 1
        break

      case 'streaming': {
        if (character === '"') {
          pos += 1
          phase = 'done'
          break scan
        }
        if (character === '\\') {
          const decoded = readEscape()
          if (decoded === 'invalid') {
            phase = 'failed'
            break scan
          }
          if (decoded === 'incomplete') break scan
          streamingChars += 1
          break
        }
        streamingChars += 1
        pos += 1
        break
      }

      case 'afterValue':
        if (isJSONWhitespace(character)) {
          pos += 1
          break
        }
        if (character === ',') {
          pos += 1
          phase = enterExpectKey()
          break
        }
        if (character === '}') {
          pos += 1
          phase = 'done'
          break scan
        }
        phase = 'failed'
        break scan
    }
  }

  return {
    complete: phase === 'done',
    failed: phase === 'failed',
    completedFields: parsePrefix(input, boundary),
    ...(field !== undefined ? { pendingField: field } : {}),
    streamingChars
  }
}

function parsePrefix(input: string, boundary: number): Record<string, unknown> {
  let prefix = input.slice(0, boundary).trimEnd()
  if (prefix.endsWith(',')) prefix = prefix.slice(0, -1)
  return safeJSONParse(`${prefix}}`).match({
    ok: value => recordValue(value) ?? {},
    err: () => ({})
  })
}

/** One tool call that was discarded with a response that hit its output limit. */
export interface TruncatedToolCall {
  name: string
  namespace?: string
  /** Whether the argument object closed before the response stopped. */
  argumentsComplete: boolean
  /** Raw characters of the argument object that arrived. */
  argumentChars: number
  /** Argument fields that completed before the stopping point. */
  completedFields: string[]
  /** Field whose value the output stopped inside, if the parser could name it. */
  cutField?: string
  /** Decoded characters of `cutField` that arrived, for a string value. */
  cutFieldChars?: number
}

/**
 * Describes how far a cut-off tool call got.
 *
 * The cut field is not known before the scan, so this reads the object twice:
 * once to name the field the output stopped inside, and once more to measure
 * how much of that field arrived. The second scan fails when the stopping
 * point is not inside a string, and the measure is then omitted.
 */
export function readTruncatedToolCall(call: {
  name: string
  namespace?: string
  arguments: string
}): TruncatedToolCall {
  const scan = scanToolInput(call.arguments)

  const truncated: TruncatedToolCall = {
    name: call.name,
    ...(call.namespace ? { namespace: call.namespace } : {}),
    argumentsComplete: scan.complete,
    argumentChars: call.arguments.length,
    completedFields: Object.keys(scan.completedFields),
    ...(scan.pendingField ? { cutField: scan.pendingField } : {})
  }

  if (!scan.pendingField) return truncated

  const measure = scanToolInput(call.arguments, scan.pendingField)
  if (measure.failed) return truncated
  return { ...truncated, cutFieldChars: measure.streamingChars }
}

function toolCallLabel(call: TruncatedToolCall): string {
  return call.namespace ? `${call.namespace}.${call.name}` : call.name
}

/**
 * Builds the text that tells the model which calls were discarded and where
 * their arguments stopped, so the next attempt does not start blind.
 */
export function describeTruncatedToolCalls(calls: TruncatedToolCall[]): string {
  const lines = [
    calls.length === 1
      ? 'Your last tool call did not run. The response reached its output-token limit while the arguments were still being written, so the incomplete call was discarded and nothing took effect.'
      : `Your last ${calls.length} tool calls did not run. The response reached its output-token limit while the arguments were still being written, so the incomplete calls were discarded and nothing took effect.`
  ]

  for (const call of calls) {
    const facts = call.argumentsComplete
      ? ['its arguments were complete, but the response was discarded before the call could run']
      : [`its arguments stopped after ${call.argumentChars} characters`]
    if (call.completedFields.length > 0) {
      facts.push(`completed fields: ${call.completedFields.join(', ')}`)
    }
    if (call.cutField !== undefined) {
      facts.push(
        call.cutFieldChars === undefined
          ? `stopped inside the value of \`${call.cutField}\``
          : `stopped inside the value of \`${call.cutField}\` after ${call.cutFieldChars} characters`
      )
    }
    lines.push(`- \`${toolCallLabel(call)}\`: ${facts.join('; ')}.`)
  }

  lines.push(
    'Make the next call fit the limit instead of repeating the same one: write the work in several smaller calls, or shorten the value that was cut. Treat every field above as not yet applied.'
  )
  return lines.join('\n')
}
