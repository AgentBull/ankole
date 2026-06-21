/**
 * Markdown parsing for External Gateway outbound payloads.
 */

import { parseMarkdownAst } from '@agentbull/bullx-native-addons'
import type { Root } from 'mdast'

/**
 * Parse markdown string into an mdast AST.
 * Supports GFM (GitHub Flavored Markdown) for strikethrough, tables, etc.
 * Parsing runs in the native addon (comrak); the returned tree is mdast-shaped.
 *
 * Adapters render their platform-native output from this shared AST, so quirk
 * handling (what each platform can and cannot show) lives in the adapters, not
 * here. This function only produces the common tree they all consume.
 */
export function parseMarkdown(markdown: string): Root {
  // The addon returns an mdast-compatible tree but is typed loosely at the FFI
  // boundary; the double cast asserts the contract once here so callers get a
  // properly typed `Root` instead of repeating the assertion.
  return parseMarkdownAst(markdown) as unknown as Root
}
