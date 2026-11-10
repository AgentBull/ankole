import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import type { ConversationAttachment } from './api'
import { ChatAttachmentDrafts, MessageAttachments } from './chat-attachments'
import { ChatAttachments } from './state/chat-attachments'

const render = (element: Parameters<typeof renderToStaticMarkup>[0]) =>
  renderToStaticMarkup(element).replace(/[⁦-⁩]/g, '')

beforeAll(async () => {
  await loadLocale('en-US')
})

const attachment = (position: number, name: string, content_type: string): ConversationAttachment => ({
  attachment_id: position + 1,
  content_type,
  name,
  object_id: `object-${position}`,
  path: `/conversations/room/${name}`,
  position,
  size: 2048
})

const cards = (markup: string) => markup.match(/<li\b[\s\S]*?<\/li>/g) ?? []

test('selecting a message file card opens its preview, so the card itself never downloads', () => {
  const markup = render(
    <MessageAttachments
      conversationID="room"
      messageID="reply"
      attachments={[
        attachment(0, 'applet-holdings-2026-11-09.png', 'image/png'),
        attachment(1, 'report.pdf', 'application/pdf'),
        attachment(2, 'bundle.zip', 'application/zip')
      ]}
      renderAction={item => <button type="button">{`Save ${item.name}`}</button>}
    />
  )
  const items = cards(markup)
  expect(items).toHaveLength(3)
  for (const [index, name] of ['applet-holdings-2026-11-09.png', 'report.pdf', 'bundle.zip'].entries()) {
    const item = items[index] ?? ''
    // The file name sits inside the single preview trigger, whatever the file type.
    const trigger = item.match(
      new RegExp(`<button type="button"[^>]*aria-label="Preview ${name.replace('.', '\\.')}"[\\s\\S]*?</button>`)
    )
    expect(trigger?.[0]).toContain(name.slice(0, name.lastIndexOf('.')))
    expect(item).not.toContain('<a ')
    expect(item).not.toContain('download=')
    // The caller's own action stays a separate control next to the card body.
    expect(trigger?.[0]).not.toContain(`Save ${name}`)
    expect(item).toContain(`<button type="button">Save ${name}</button>`)
  }
  expect(items[0]).toContain('<img')
})

test('a selected draft file opens the same preview from its card instead of downloading the local copy', () => {
  const model = new ChatAttachments(async () => ({
    receipt: 'prepared',
    name: 'notes.txt',
    size: 5,
    content_type: 'text/plain'
  }))
  const previous = URL.createObjectURL
  URL.createObjectURL = () => 'blob:draft'
  try {
    model.add([new File(['notes'], 'notes.txt', { type: 'text/plain' })])
    const [item] = cards(render(<ChatAttachmentDrafts model={model} />))
    const trigger = item?.match(/<button[^>]*aria-label="Preview notes\.txt"[\s\S]*?<\/button>/)?.[0]
    expect(trigger).toContain('notes')
    expect(trigger).toContain('role="status"')
    expect(item).not.toContain('<a ')
    expect(item).not.toContain('download=')
    expect(item).toContain('aria-label="Remove notes.txt"')
  } finally {
    model.dispose()
    URL.createObjectURL = previous
  }
})
