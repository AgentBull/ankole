export interface FuzzyMatch {
  end: number
  exact: boolean
  start: number
  strategy: string
}

interface LineSpan {
  end: number
  start: number
  text: string
}

const STRATEGIES: Array<{ name: string; normalize: (line: string) => string }> = [
  { name: 'trim_trailing_whitespace', normalize: line => line.replace(/[ \t]+$/g, '') },
  { name: 'trim_line_edges', normalize: line => line.trim() },
  { name: 'normalize_horizontal_whitespace', normalize: line => line.trim().replace(/[ \t]+/g, ' ') }
]

export function findUniqueFuzzyMatch(haystack: string, needle: string): FuzzyMatch | undefined {
  if (!needle) return undefined
  const exact = uniqueExactMatch(haystack, needle)
  if (exact) return exact
  if (!needle.includes('\n')) return undefined

  const haystackLines = lineSpans(haystack)
  const needleLines = splitLines(needle)
  if (needleLines.length === 0 || needleLines.length > haystackLines.length) return undefined

  for (const strategy of STRATEGIES) {
    const normalizedNeedle = needleLines.map(strategy.normalize).join('\n')
    const matches: FuzzyMatch[] = []
    for (let startLine = 0; startLine <= haystackLines.length - needleLines.length; startLine++) {
      const window = haystackLines.slice(startLine, startLine + needleLines.length)
      const normalizedWindow = window.map(line => strategy.normalize(line.text)).join('\n')
      if (normalizedWindow !== normalizedNeedle) continue
      matches.push({
        start: window[0]!.start,
        end: window[window.length - 1]!.end,
        exact: false,
        strategy: strategy.name
      })
      if (matches.length > 1) break
    }
    if (matches.length === 1) return matches[0]
    if (matches.length > 1) return undefined
  }

  return undefined
}

function uniqueExactMatch(haystack: string, needle: string): FuzzyMatch | undefined {
  const start = haystack.indexOf(needle)
  if (start === -1) return undefined
  if (haystack.indexOf(needle, start + needle.length) !== -1) return undefined
  return { start, end: start + needle.length, exact: true, strategy: 'exact' }
}

function lineSpans(value: string): LineSpan[] {
  const lines = splitLines(value)
  const spans: LineSpan[] = []
  let offset = 0
  for (const line of lines) {
    const start = offset
    offset += line.length
    spans.push({ start, end: offset, text: line })
    if (value[offset] === '\n') offset += 1
  }
  return spans
}

function splitLines(value: string): string[] {
  if (!value) return []
  const lines = value.split('\n')
  if (lines.at(-1) === '') lines.pop()
  return lines
}
