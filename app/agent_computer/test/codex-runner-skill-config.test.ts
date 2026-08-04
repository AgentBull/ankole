import { describe, expect, it } from 'bun:test'
import { verifiedCodexSkills } from '../src/core/codex-runner'

describe('@ankole/agent-computer Codex project Skill discovery', () => {
  it('uses native project discovery without mutating process-global Skill configuration', async () => {
    const cwd = '/agents/agent-1/jobs/job-1'
    const requests: Array<{ method: string; params: unknown }> = []
    const client = {
      async request(method: string, params: unknown) {
        requests.push({ method, params })
        if (method !== 'skills/list') throw new Error(`unexpected method ${method}`)
        return {
          data: [
            {
              cwd,
              errors: [],
              skills: [
                { name: 'coding', enabled: true, path: `${cwd}/.agents/skills/coding/SKILL.md` },
                { name: 'docx', enabled: true, path: `${cwd}/.agents/skills/docx/SKILL.md` },
                { name: 'disabled', enabled: false, path: `${cwd}/.agents/skills/disabled/SKILL.md` }
              ]
            }
          ]
        }
      }
    }

    await expect(verifiedCodexSkills(client, cwd, ['coding', 'docx'])).resolves.toEqual([
      { name: 'coding', enabled: true, path: `${cwd}/.agents/skills/coding/SKILL.md` },
      { name: 'docx', enabled: true, path: `${cwd}/.agents/skills/docx/SKILL.md` },
      { name: 'disabled', enabled: false, path: `${cwd}/.agents/skills/disabled/SKILL.md` }
    ])
    expect(requests).toEqual([{ method: 'skills/list', params: { cwds: [cwd], forceReload: true } }])
  })

  it('rejects missing, disabled, and malformed native discovery results', async () => {
    const cwd = '/agents/agent-1/jobs/job-1'
    const disabledClient = {
      async request() {
        return {
          data: [
            {
              cwd,
              errors: [],
              skills: [{ name: 'coding', enabled: false, path: `${cwd}/.agents/skills/coding/SKILL.md` }]
            }
          ]
        }
      }
    }
    await expect(verifiedCodexSkills(disabledClient, cwd, ['coding', 'docx'])).rejects.toThrow(
      'Codex did not discover enabled project Skills: coding, docx'
    )

    const errorClient = {
      async request() {
        return { data: [{ cwd, errors: [{ path: `${cwd}/.agents/skills/bad`, message: 'invalid frontmatter' }] }] }
      }
    }
    await expect(verifiedCodexSkills(errorClient, cwd, [])).rejects.toThrow(
      'Codex skill discovery failed: /agents/agent-1/jobs/job-1/.agents/skills/bad: invalid frontmatter'
    )

    const malformedClient = {
      async request() {
        return { data: [{ cwd, errors: [], skills: [{ name: 'coding', enabled: true }] }] }
      }
    }
    await expect(verifiedCodexSkills(malformedClient, cwd, ['coding'])).rejects.toThrow(
      'Codex skills/list returned an invalid Skill at index 0'
    )
  })
})
