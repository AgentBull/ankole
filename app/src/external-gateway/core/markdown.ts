/**
 * Markdown parsing for External Gateway outbound payloads.
 */

import { parseMarkdownAst } from '@agentbull/bullx-native-addons'
import type { Root } from 'mdast'

/**
 * Parse markdown string into an mdast AST.
 * Supports GFM (GitHub Flavored Markdown) for strikethrough, tables, etc.
 * Parsing runs in the native addon (comrak); the returned tree is mdast-shaped.
 */
export function parseMarkdown(markdown: string): Root {
  return parseMarkdownAst(markdown) as unknown as Root
}
