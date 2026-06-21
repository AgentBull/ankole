/**
 * Plain-text rendering + answer mapping for clarify (hermes base.py parity).
 * Pure functions — unit-testable without DB/registry.
 */

/** Render a clarify question as a numbered plain-text prompt. */
export function renderClarifyPrompt(question: string, choices?: string[]): string {
  if (!choices || choices.length === 0) {
    return `❓ ${question}\n\nReply with your answer.`
  }
  const lines = [`❓ ${question}`, '']
  choices.forEach((choice, index) => lines.push(`${index + 1}. ${choice}`))
  lines.push('')
  lines.push('Reply with a number, the option text, or your own answer.')
  return lines.join('\n')
}

export interface MappedAnswer {
  text: string
  choiceIndex?: number
}

/**
 * Map a free-form reply to a choice when possible: a bare number (1-based), an
 * exact case-insensitive option match, else free text (hermes "number / text /
 * own answer").
 */
export function mapAnswer(reply: string, choices?: string[]): MappedAnswer {
  const trimmed = reply.trim()
  if (!choices || choices.length === 0) return { text: trimmed }

  // A bare number is read as a 1-based pick, but only inside range — an
  // out-of-range number ("9" against 3 options) falls through to be treated as
  // free text rather than silently resolving to the wrong choice.
  if (/^\d+$/.test(trimmed)) {
    const n = Number.parseInt(trimmed, 10)
    if (n >= 1 && n <= choices.length) {
      const picked = choices[n - 1]
      if (picked !== undefined) return { text: picked, choiceIndex: n - 1 }
    }
  }

  const lower = trimmed.toLowerCase()
  const matchIndex = choices.findIndex(choice => choice.toLowerCase() === lower)
  const matched = matchIndex >= 0 ? choices[matchIndex] : undefined
  if (matched !== undefined) return { text: matched, choiceIndex: matchIndex }

  return { text: trimmed }
}
