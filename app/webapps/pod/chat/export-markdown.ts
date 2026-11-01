import type { ConversationDetail, ConversationMessage } from '../api'

export function messageMarkdown(message: Pick<ConversationMessage, 'text' | 'links'>): string {
  const lines: string[] = []
  for (const link of message.links) {
    if (link.kind === 'message' && link.quote) {
      lines.push(
        link.quote
          .split('\n')
          .map(line => `> ${line}`)
          .join('\n'),
        ''
      )
    }
  }
  lines.push(message.text, '')
  for (const link of message.links) {
    if (link.kind === 'page' && !message.text.includes(`ankole:page/${link.id}`)) {
      lines.push(`- [Page](ankole:page/${link.id})`)
    }
  }
  return lines.join('\n')
}

export function selectionToMarkdown(messages: ConversationMessage[], options: { title?: string } = {}): string {
  const ordered = [...messages].sort((a, b) => a.seq - b.seq)
  const lines: string[] = []
  if (options.title?.trim()) {
    lines.push(`# ${options.title.trim()}`, '')
  }
  for (const message of ordered) {
    const name = message.authorDisplayName || message.authorType
    lines.push(`## ${name} · ${message.createdAt}`, '', messageMarkdown(message))
    for (const attachment of message.attachments) {
      lines.push(`- ${attachment.name}`)
    }
    if (message.attachments.length > 0) {
      lines.push('')
    }
  }
  const normalized = lines.join('\n').trimEnd()
  return `${normalized}\n`
}

export function conversationMarkdown(detail: ConversationDetail): string {
  const lines = [`# ${detail.conversation.title}`, '']
  for (const message of detail.messages) {
    const name = message.authorDisplayName || message.authorType
    lines.push(`## ${name} · ${message.createdAt}`, '', messageMarkdown(message))
    for (const attachment of message.attachments) lines.push(`- ${attachment.name}`)
  }
  return lines.join('\n')
}

export function downloadMarkdownString(markdown: string, filenameBase: string) {
  const url = URL.createObjectURL(new Blob([markdown], { type: 'text/markdown;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = `${filenameBase.replace(/[/\\:*?"<>|]/g, '_').trim() || 'conversation'}.md`
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export function downloadMarkdown(detail: ConversationDetail) {
  downloadMarkdownString(conversationMarkdown(detail), detail.conversation.title || 'conversation')
}
