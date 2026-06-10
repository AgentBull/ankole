import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { MockImPlatform } = await import('./mock-im-adapter')

describe('Mock IM adapter attachments', () => {
  it('maps resource descriptors into fetchable attachments like Lark resources', async () => {
    const platform = new MockImPlatform()
    const adapter = platform.createAdapter('mock')
    const dm = platform.dm({ adapterName: 'mock', agentUid: 'agent-1' })
    const raw = dm.payload({
      attachments: [
        {
          data: 'mock attachment body',
          mimeType: 'text/plain',
          name: 'inbound.txt',
          type: 'file'
        }
      ],
      id: 'm1',
      text: 'see attached'
    })

    expect(raw.attachments?.[0]).toMatchObject({
      fileName: 'inbound.txt',
      mimeType: 'text/plain',
      resourceType: 'file'
    })
    expect(raw.attachments?.[0]).not.toHaveProperty('data')

    const parsed = adapter.parseMessage(raw)
    expect(parsed.attachments?.[0]).toMatchObject({
      fetchMetadata: {
        provider: 'mock-im',
        resourceType: 'file',
        downloadType: 'file',
        messageId: 'm1'
      },
      mimeType: 'text/plain',
      name: 'inbound.txt',
      type: 'file'
    })
    expect(await parsed.attachments?.[0]?.fetchData?.()).toEqual(Buffer.from('mock attachment body'))
  })
})
