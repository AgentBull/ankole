import type { Options } from 'react-markdown'
import remarkCjkFriendly from 'remark-cjk-friendly'
import remarkCjkFriendlyGfmStrikethrough from 'remark-cjk-friendly-gfm-strikethrough'
import remarkGfm from 'remark-gfm'

/**
 * The Markdown syntax that Ankole's renderers parse: GitHub Flavored Markdown with the CJK-friendly rules for
 * emphasis and strikethrough.
 *
 * CommonMark lets a `**`, `*` or `~~` open or close only where a Western word boundary would stand: a closing mark
 * that follows punctuation must meet a space or more punctuation. Chinese, Japanese and Korean put no space
 * between words, so under that rule `**验收：**选择` keeps its asterisks, because its closing mark follows `：` and
 * meets a letter. The CJK-friendly rules also accept a mark that touches a CJK character, and they leave text in
 * other scripts as CommonMark reads it.
 */
export const MARKDOWN_SYNTAX_PLUGINS: NonNullable<Options['remarkPlugins']> = [
  remarkGfm,
  remarkCjkFriendly,
  remarkCjkFriendlyGfmStrikethrough
]
