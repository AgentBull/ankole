'use client'

import type { EmojiRenderProps } from 'emoji-picker-react/primitives'
import { cn } from '../lib/utils'

/**
 * The grid cell keeps the library-owned button attributes and renders the glyph
 * with Fluent Emoji Color. Custom image emojis keep the default cell content.
 */
export function EmojiPickerCell({ emoji, children, className, ...props }: EmojiRenderProps) {
  return (
    <button {...props} className={cn('ankole-emoji-cell', className)}>
      {emoji.isCustom ? children : <span className="ankole-fluent-emoji">{emoji.emoji}</span>}
    </button>
  )
}
