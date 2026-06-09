import { describe, expect, it } from 'bun:test'
import { createPatchTool } from './patch-tool'

describe('patch tool', () => {
  it('preserves UTF-8 BOM and CRLF line endings when replacing text', async () => {
    let written = ''
    const tool = createPatchTool({
      agentUid: 'agent',
      backgroundIds: new Set(),
      getComputer: async () =>
        ({
          readFileToBuffer: async () => Buffer.from('\ufefffirst\r\nsecond\r\n', 'utf-8'),
          fs: {
            writeFiles: async (files: Array<{ content: string }>) => {
              written = files[0]!.content
            }
          }
        }) as any
    })

    await tool.execute(
      'call',
      {
        path: 'demo.txt',
        old_string: 'first\nsecond\n',
        new_string: 'first\nupdated\n'
      },
      undefined
    )

    expect(written).toBe('\ufefffirst\r\nupdated\r\n')
  })
})
