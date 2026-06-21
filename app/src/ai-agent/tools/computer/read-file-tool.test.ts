import { describe, expect, it } from 'bun:test'
import type { Computer } from '@agentbull/bullx-computer'

// Loaded via dynamic import rather than a static one (unlike the sibling tool tests).
const { createReadFileTool } = await import('./read-file-tool')

describe('read_file tool', () => {
  // Pins that `workdir` maps onto `cwd` for the underlying read, and that output is the
  // numbered `LINE_NUM|CONTENT` format (here `1|first`).
  it('accepts workdir as a cwd alias for consistency with command', async () => {
    const reads: unknown[] = []
    const computer = {
      async readFileToBuffer(params: unknown) {
        reads.push(params)
        return Buffer.from('first\nsecond\n')
      }
    } as unknown as Computer
    const tool = createReadFileTool({
      agentUid: 'agent_123',
      executionScopeId: 'scope_123',
      backgroundIds: new Set(),
      getComputer: async () => computer
    })

    const result = await tool.execute('tc_read', {
      path: 'app/db/meta/_journal.json',
      workdir: '/workspace/user-files/repo',
      limit: 1
    })

    expect(reads).toEqual([{ path: 'app/db/meta/_journal.json', cwd: '/workspace/user-files/repo' }])
    expect(result.content[0]).toMatchObject({ type: 'text', text: expect.stringContaining('1|first') })
  })
})
