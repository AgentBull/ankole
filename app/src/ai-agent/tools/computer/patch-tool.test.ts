import { describe, expect, it } from 'bun:test'
import { createPatchTool } from './patch-tool'

describe('patch tool', () => {
  // Pins that `workdir` is honored as an alias for `cwd`, and that the SAME base dir is
  // threaded through both the read and the write so an edit lands back where it was read.
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

  // Pins the encoding-preservation rule: matching happens on a normalized (LF, no-BOM)
  // copy, but the file is written back with its original BOM and CRLF endings intact, so
  // the edit shows up as a content change and not a whole-file line-ending churn. The
  // needle/replacement are given in LF form and still match the CRLF file.
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
