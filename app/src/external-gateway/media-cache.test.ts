import { describe, expect, it } from 'bun:test'
import posix from 'node:path/posix'
import type { ComputerFile } from '@agentbull/bullx-computer'
import { materializeInboundMessageAttachments, type ExternalMediaComputerWriter } from './media-cache'
import type { ExternalGatewayMessageInput } from './core/events'

describe('External Gateway media cache', () => {
  it('saves supported documents through the computer writer and exposes computer paths', async () => {
    const storage = createComputerStorage()
    const message = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: '../report.pdf',
        mimeType: 'application/pdf',
        type: 'file',
        fetchData: async () => Buffer.from('%PDF-1.7')
      }),
      testOptions(storage)
    )

    expect(message.text).toContain("[document 'report.pdf' saved at: /workspace/user-files/external-gateway/")
    const materialized = (message.attachments![0] as any).materialized
    expect(materialized).toMatchObject({
      displayName: 'report.pdf',
      kind: 'document',
      mimeType: 'application/pdf',
      status: 'saved'
    })
    expect(materialized).not.toHaveProperty('hostPath')
    expect(storage.writes[0]?.path).toBe(materialized.computerPath)
    expect(storage.read(materialized.computerPath)?.toString('utf8')).toBe('%PDF-1.7')
    expect(message.attachments![0]).not.toHaveProperty('fetchData')
    expect(message.attachments![0]).not.toHaveProperty('data')
  })

  it('inlines only small txt and markdown documents', async () => {
    const markdown = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: 'notes.md',
        mimeType: 'text/markdown',
        type: 'file',
        data: '# Meeting notes'
      }),
      testOptions(createComputerStorage())
    )
    expect(markdown.text).toContain('[Content of notes.md]:\n# Meeting notes')

    const csv = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: 'rows.csv',
        mimeType: 'text/csv',
        type: 'file',
        data: 'a,b\n1,2'
      }),
      testOptions(createComputerStorage())
    )
    expect(csv.text).toContain("[document 'rows.csv' saved at:")
    expect(csv.text).not.toContain('[Content of rows.csv]')
  })

  it('rejects unsupported documents before fetching bytes', async () => {
    const storage = createComputerStorage()
    let fetched = false
    const message = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: 'installer.exe',
        type: 'file',
        fetchData: async () => {
          fetched = true
          return Buffer.from('MZ')
        }
      }),
      testOptions(storage)
    )

    expect(fetched).toBe(false)
    expect(storage.writes).toHaveLength(0)
    expect(message.text).toContain("[attachment 'installer.exe' could not be saved: unsupported attachment type]")
    expect((message.attachments![0] as any).materialized).toMatchObject({
      displayName: 'installer.exe',
      status: 'unsupported'
    })
  })

  it('rejects image attachments whose bytes do not look like an image', async () => {
    const storage = createComputerStorage()
    const message = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: 'not-image.png',
        mimeType: 'image/png',
        type: 'image',
        data: 'plain text'
      }),
      testOptions(storage)
    )

    expect(storage.writes).toHaveLength(0)
    expect(message.text).toContain("[attachment 'not-image.png' could not be saved: invalid image data]")
    expect((message.attachments![0] as any).materialized.status).toBe('unsupported')
  })

  it('sniffs image bytes instead of trusting declared mime type or extension', async () => {
    const storage = createComputerStorage()
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      'base64'
    )
    const message = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: 'image.jpg',
        mimeType: 'image/jpeg',
        type: 'image',
        data: png
      }),
      testOptions(storage)
    )

    const materialized = (message.attachments![0] as any).materialized
    expect(materialized).toMatchObject({
      displayName: 'image.jpg',
      kind: 'image',
      mimeType: 'image/png',
      status: 'saved'
    })
    expect(materialized.computerPath).toEndWith('.png')
    expect(storage.read(materialized.computerPath)).toEqual(png)
  })

  it('does not overwrite repeated filenames', async () => {
    const storage = createComputerStorage()
    const message = await materializeInboundMessageAttachments(
      {
        ...messageWithAttachment({
          name: 'report.pdf',
          mimeType: 'application/pdf',
          type: 'file',
          data: '%PDF-one'
        }),
        attachments: [
          {
            name: 'report.pdf',
            mimeType: 'application/pdf',
            type: 'file',
            data: '%PDF-one'
          },
          {
            name: 'report.pdf',
            mimeType: 'application/pdf',
            type: 'file',
            data: '%PDF-two'
          }
        ]
      },
      testOptions(storage)
    )
    const first = (message.attachments![0] as any).materialized
    const second = (message.attachments![1] as any).materialized
    expect(first.computerPath).not.toBe(second.computerPath)
    expect(storage.read(first.computerPath)?.toString('utf8')).toBe('%PDF-one')
    expect(storage.read(second.computerPath)?.toString('utf8')).toBe('%PDF-two')
  })

  it('leaves agent uid scoping to the computer session', async () => {
    const storage = createComputerStorage()
    const message = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: 'report.pdf',
        mimeType: 'application/pdf',
        type: 'file',
        data: '%PDF-unicode-agent'
      }),
      { ...testOptions(storage), agentUid: 'agentbull测试' }
    )
    const materialized = (message.attachments![0] as any).materialized

    expect(materialized.computerPath).toContain('/workspace/user-files/external-gateway/')
    expect(materialized.computerPath).not.toContain('agentbull测试')
    expect(storage.read(materialized.computerPath)?.toString('utf8')).toBe('%PDF-unicode-agent')
  })

  it('preserves unicode attachment filenames', async () => {
    const storage = createComputerStorage()
    const message = await materializeInboundMessageAttachments(
      messageWithAttachment({
        name: '守信承诺书.pdf',
        mimeType: 'application/pdf',
        type: 'file',
        data: '%PDF-unicode-name'
      }),
      testOptions(storage)
    )
    const materialized = (message.attachments![0] as any).materialized

    expect(materialized.displayName).toBe('守信承诺书.pdf')
    expect(materialized.computerPath).toContain('守信承诺书.pdf')
    expect(message.text).toContain("[document '守信承诺书.pdf' saved at:")
    expect(storage.read(materialized.computerPath)?.toString('utf8')).toBe('%PDF-unicode-name')
  })
})

function messageWithAttachment(
  attachment: NonNullable<ExternalGatewayMessageInput['attachments']>[number]
): ExternalGatewayMessageInput {
  return {
    attachments: [attachment],
    author: { fullName: 'Alice', isBot: false, isMe: false, userId: 'alice', userName: 'Alice' },
    id: 'm1',
    isMention: true,
    text: '',
    threadId: 'fake:room:thread'
  }
}

function testOptions(storage: ExternalMediaComputerWriter) {
  return {
    agentUid: 'agent-1',
    binding: { adapter: 'fake', groupMessageMode: 'addressed_only' as const, name: 'main' },
    computerWriter: async () => storage,
    room: { id: 'fake:room', isDM: false }
  }
}

function createComputerStorage(): ExternalMediaComputerWriter & {
  read(path: string): Buffer | undefined
  writes: Array<{ content: Buffer; path: string }>
} {
  const files = new Map<string, Buffer>()
  const writes: Array<{ content: Buffer; path: string }> = []
  return {
    writes,
    async writeFiles(computerFiles: ComputerFile[], opts: { cwd?: string } = {}) {
      for (const file of computerFiles) {
        const path = normalizeComputerPath(file.path, opts.cwd ?? '/workspace')
        const content = await contentBuffer(file.content)
        files.set(path, content)
        writes.push({ path, content })
      }
    },
    read(path: string) {
      return files.get(posix.normalize(path))
    }
  }
}

function normalizeComputerPath(path: string, cwd: string): string {
  return posix.normalize(path.startsWith('/') ? path : `${cwd.replace(/\/+$/u, '')}/${path}`)
}

async function contentBuffer(content: ComputerFile['content']): Promise<Buffer> {
  if (typeof content === 'string') return Buffer.from(content)
  if (content instanceof Blob) return Buffer.from(await content.arrayBuffer())
  return Buffer.from(content)
}
