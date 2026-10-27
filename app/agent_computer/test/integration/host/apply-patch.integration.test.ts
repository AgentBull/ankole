import { chownAgentPathSync, mkdirAgentSync } from '../../../src/common/agent-user'
import { expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createContainerComputer } from '../../../src/tools/computer/computer'
import { createApplyPatchTool } from '../../../src/tools/computer/apply-patch-tool'

it('edits files through the native apply_patch binary', async () => {
  const agentHome = mkdtempSync(join(tmpdir(), 'ankole-native-apply-patch-'))
  mkdirAgentSync(agentHome, 0o700)
  const workspaceRoot = join(agentHome, 'sessions', 'session-1')
  mkdirAgentSync(workspaceRoot)
  writeFileSync(join(workspaceRoot, 'report.md'), 'old\n')
  writeFileSync(join(workspaceRoot, 'stale.md'), 'remove\n')
  chownAgentPathSync(join(workspaceRoot, 'report.md'))
  chownAgentPathSync(join(workspaceRoot, 'stale.md'))

  try {
    const computer = createContainerComputer(agentHome, workspaceRoot)
    const tool = createApplyPatchTool({
      agentHome,
      workspaceRoot,
      computer
    })

    await tool.execute(
      'call-native-apply-patch',
      [
        '*** Begin Patch',
        '*** Update File: report.md',
        '@@',
        '-old',
        '+new',
        '*** Add File: created.md',
        '+created',
        '*** Delete File: stale.md',
        '*** End Patch',
        ''
      ].join('\n')
    )

    expect(readFileSync(join(workspaceRoot, 'report.md'), 'utf8')).toBe('new\n')
    expect(readFileSync(join(workspaceRoot, 'created.md'), 'utf8')).toBe('created\n')
    expect(() => readFileSync(join(workspaceRoot, 'stale.md'), 'utf8')).toThrow()
  } finally {
    rmSync(agentHome, { recursive: true, force: true })
  }
})
