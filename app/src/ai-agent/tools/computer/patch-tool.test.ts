import { describe, expect, it } from 'bun:test'
import { createPatchTool } from './patch-tool'

describe('patch tool', () => {
  it('accepts workdir as a cwd alias for replace mode reads and writes', async () => {
    const reads: unknown[] = []
    const writes: unknown[] = []
    const tool = createPatchTool({
      agentUid: 'agent',
      executionScopeId: 'test-scope',
      backgroundIds: new Set(),
      getComputer: async () =>
        ({
          readFileToBuffer: async (params: unknown) => {
            reads.push(params)
            return Buffer.from('const value = 1\n', 'utf-8')
          },
          fs: {
            writeFiles: async (files: unknown, opts: unknown) => {
              writes.push({ files, opts })
            }
          }
        }) as any
    })

    await tool.execute(
      'call',
      {
        path: 'src/index.ts',
        old_string: 'const value = 1\n',
        new_string: 'const value = 2\n',
        workdir: '/workspace/user-files/repo'
      },
      undefined
    )

    expect(reads).toEqual([{ path: 'src/index.ts', cwd: '/workspace/user-files/repo' }])
    expect(writes[0]).toMatchObject({
      files: [{ path: 'src/index.ts', content: 'const value = 2\n' }],
      opts: { cwd: '/workspace/user-files/repo', signal: undefined }
    })
  })

  it('preserves UTF-8 BOM and CRLF line endings when replacing text', async () => {
    let written = ''
    const tool = createPatchTool({
      agentUid: 'agent',
      executionScopeId: 'test-scope',
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
