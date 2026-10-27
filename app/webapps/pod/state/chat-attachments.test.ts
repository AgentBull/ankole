import { describe, expect, test } from 'bun:test'
import { ChatAttachments } from './chat-attachments'
import { ChatModel } from './chat'
import { ChatDrafts } from './chat-drafts'

const receipt = (value: string) => ({ receipt: value, name: 'brief.txt', size: 5, content_type: 'text/plain' })
const tick = async () => {
  await Promise.resolve()
  await Promise.resolve()
}
const file = () => new File(['brief'], 'brief.txt', { type: 'text/plain' })

describe('Human chat attachments', () => {
  test('uploads keep a UUID identity when randomUUID is unavailable on the origin', async () => {
    const previous = Object.getOwnPropertyDescriptor(crypto, 'randomUUID')
    Object.defineProperty(crypto, 'randomUUID', { configurable: true, value: undefined })
    const model = new ChatAttachments(async () => receipt('prepared'))
    try {
      model.add([file()])
      await tick()
      expect(model.canSend.value).toBe(true)
      expect(model.capture().attachmentIDs[0]).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      )
    } finally {
      model.dispose()
      if (previous) Object.defineProperty(crypto, 'randomUUID', previous)
      else Reflect.deleteProperty(crypto, 'randomUUID')
    }
  })

  test('an upload failure keeps the File and retries with the same upload identity', async () => {
    const calls: string[] = []
    const model = new ChatAttachments(async (_file, id) => {
      calls.push(id)
      if (calls.length === 1) throw new Error('Network disconnected')
      return receipt('prepared')
    })
    const source = file()
    model.add([source])
    const first = model.files.peek()[0]!
    expect(model.canSend.value).toBe(false)
    await tick()
    expect(model.files.peek()[0]!.state).toBe('failed')
    expect(model.files.peek()[0]!.file).toBe(source)
    model.retry(first.id)
    await tick()
    expect(calls).toEqual([first.id, first.id])
    expect(model.capture()).toEqual({ attachments: ['prepared'], attachmentIDs: [first.id] })
    model.dispose()
  })

  test('remove aborts work and a late upload response cannot restore the removed attachment', async () => {
    let finish!: (result: ReturnType<typeof receipt>) => void
    let request!: AbortSignal
    const model = new ChatAttachments((_file, _id, signal) => {
      request = signal
      return new Promise(resolve => {
        finish = resolve
      })
    })
    model.add([file()])
    model.remove(model.files.peek()[0]!.id)
    expect(request.aborted).toBe(true)
    finish(receipt('late response'))
    await tick()
    expect(model.files.peek()).toEqual([])
    expect(model.hasFiles.value).toBe(false)
  })

  test('an uncertain Message retry keeps both IDs when its upload receipt is renewed', () => {
    const model = new ChatModel()
    model.attachments.files.value = [
      { id: 'file-1', file: file(), url: 'blob:test', state: 'ready', receipt: 'first lease' }
    ]
    let sequence = 0
    const id = () => `id-${++sequence}`
    const first = model.submit(undefined, 'agent', id)
    model.failed(new Error('Response was lost'), first.messageID)
    model.attachments.files.value = [{ ...model.attachments.files.peek()[0]!, receipt: 'renewed lease' }]
    const retry = model.submit(undefined, 'agent', id)
    expect(retry.conversationID).toBe(first.conversationID)
    expect(retry.messageID).toBe(first.messageID)
    expect(retry.attachments).toEqual(['renewed lease'])
    expect(sequence).toBe(2)
    model.attachments.dispose()
  })

  test('a late acceptance clears captured files and preserves attachments added for the next message', () => {
    const model = new ChatModel()
    const initial = { id: 'file-1', file: file(), url: 'blob:one', state: 'ready' as const, receipt: 'one' }
    model.attachments.files.value = [initial]
    const sent = model.submit('conversation', 'agent', () => 'message')
    model.attachments.files.value = [initial, { ...initial, id: 'file-2', url: 'blob:two', receipt: 'two' }]
    model.accepted(sent)
    expect(model.attachments.files.peek().map(file => file.id)).toEqual(['file-2'])
    expect(model.hasContent.value).toBe(true)
    model.attachments.dispose()
  })

  test('closing a Page chat retains local File work under its existing draft owner', () => {
    const drafts = new ChatDrafts()
    const first = drafts.get(undefined, 'report')
    first.attachments.files.value = [{ id: 'upload', file: file(), url: 'blob:local', state: 'failed' }]
    expect(drafts.hasUnsentWork()).toBe(true)
    expect(drafts.unfinishedPageConversation('report')).toBe('new')
    expect(drafts.get(undefined, 'report')).toBe(first)
    expect(drafts.localPageAttachments('other')).toEqual([])
    expect(drafts.localPageAttachments('report')).toEqual([first.attachments])
    drafts.dispose()
    expect(first.attachments.files.peek()).toEqual([])
  })
})
