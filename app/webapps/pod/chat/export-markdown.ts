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

export function conversationMarkdown(detail: ConversationDetail): string {
  const lines = [`# ${detail.conversation.title}`, '']
  for (const message of detail.messages) {
    const name = message.authorDisplayName || message.authorType
    lines.push(`## ${name} · ${message.createdAt}`, '', messageMarkdown(message))
    for (const attachment of message.attachments) lines.push(`- ${attachment.name}`)
  }
  return lines.join('\n')
}

export function downloadMarkdown(detail: ConversationDetail) {
  const url = URL.createObjectURL(new Blob([conversationMarkdown(detail)], { type: 'text/markdown;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = `${detail.conversation.title.replace(/[/\\:*?"<>|]/g, '_') || 'conversation'}.md`
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
