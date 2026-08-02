import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const scriptPath = join(
  import.meta.dir,
  '..',
  '..',
  'library',
  'agent-plugins',
  'deep-research',
  'workspace-template',
  'tools',
  'list_playbooks.ts'
)

describe('@ankole/agent-computer Deep Research Playbook discovery', () => {
  it('prints every Playbook path and routing description from front matter', async () => {
    const result = await runDiscovery()

    expect(result.exitCode).toBe(0)
    expect(result.stderr).toBe('')
    expect(result.stdout.trim().split('\n')).toEqual([
      'Available Playbooks:',
      '- academic-verify (playbooks/AcademicVerify.md): Use when the requested research deliverable verifies a specified academic claim, study, paper, or citation by tracing it through the original publication, methodology, source data, publication status, and independent replication.',
      '- ach (playbooks/ACH.md): Use when an important forecast or diagnosis must compare plausible explanations under incomplete, noisy, conflicting, or possibly deceptive information.',
      '- analogical-foresight (playbooks/AnalogicalForesight.md): Use when historical cases can reveal mechanisms, variables, and tests for a defined uncertainty in a forward-looking analysis.'
    ])
  })

  it('fails when a Playbook omits its routing description', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-playbooks-'))
    writeFileSync(join(root, 'invalid.md'), '---\nname: invalid\n---\n\n# Invalid\n')

    try {
      const result = await runDiscovery(root)
      expect(result.exitCode).not.toBe(0)
      expect(result.stderr).toContain('playbooks/invalid.md: description must be a non-empty string')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

async function runDiscovery(root?: string) {
  const process = Bun.spawn(['bun', scriptPath, ...(root ? [root] : [])], { stdout: 'pipe', stderr: 'pipe' })
  const [exitCode, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text()
  ])
  return { exitCode, stdout, stderr }
}
