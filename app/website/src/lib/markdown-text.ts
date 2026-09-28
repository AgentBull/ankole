import type { Locale } from '../i18n/config'

/** What a docs MDX component receives when the build writes its Markdown form. */
export interface ComponentMarkdownContext {
  /** Markdown of the element children, with links already rewritten. */
  children: string
  /** Depth of the heading that contains the element. The page title has depth 1. */
  depth: number
  /** Resolves an href written for the HTML page to the target that the Markdown publishes. */
  link: (href: string) => string
  /** Absolute URL of the Markdown version of a docs page. */
  docMarkdownUrl: (locale: Locale, slug: string) => string
}

/** Writes the Markdown form of one docs MDX component from the same props that the page receives. */
export type ComponentMarkdownRenderer = (props: Record<string, unknown>, context: ComponentMarkdownContext) => string

export function requiredProp<T>(props: Record<string, unknown>, name: string): T {
  if (props[name] === undefined) throw new Error(`the ${name} prop is missing`)
  return props[name] as T
}

/** Joins Markdown blocks with one blank line and drops empty blocks. */
export function blocks(...parts: (string | false | null | undefined)[]): string {
  return parts
    .filter((part): part is string => typeof part === 'string' && part.trim() !== '')
    .map(part => part.trim())
    .join('\n\n')
}

/** An ATX heading. Markdown has six levels, so deeper sections stay at level 6. */
export function heading(depth: number, text: string): string {
  return `${'#'.repeat(Math.min(Math.max(depth, 1), 6))} ${text}`
}

export function blockquote(text: string): string {
  return text
    .split('\n')
    .map(line => (line === '' ? '>' : `> ${line}`))
    .join('\n')
}

export function bulletList(items: readonly string[] | undefined): string {
  return (items ?? []).map(item => `- ${indentContinuation(item, 2)}`).join('\n')
}

export function orderedList(items: readonly string[] | undefined): string {
  return (items ?? []).map((item, index) => `${index + 1}. ${indentContinuation(item, 3)}`).join('\n')
}

/** A fenced code block whose fence is longer than any backtick run in the code. */
export function fence(code: string, language = ''): string {
  const marker = '`'.repeat(Math.max(3, longestRun(code, '`') + 1))
  return `${marker}${language}\n${code.replace(/\n+$/, '')}\n${marker}`
}

export function inlineCode(value: string): string {
  const marker = '`'.repeat(longestRun(value, '`') + 1)
  const padding = value.startsWith('`') || value.endsWith('`') ? ' ' : ''
  return `${marker}${padding}${value}${padding}${marker}`
}

function indentContinuation(text: string, width: number): string {
  return text.replaceAll('\n', `\n${' '.repeat(width)}`)
}

function longestRun(text: string, character: string): number {
  let longest = 0
  let current = 0
  for (const next of text) {
    current = next === character ? current + 1 : 0
    longest = Math.max(longest, current)
  }
  return longest
}
