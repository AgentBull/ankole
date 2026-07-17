import { describe, expect, it } from 'bun:test'
import { configureCodexSkills } from '../src/core/codex-runner'
import type { PreparedAgentPlugins } from '../src/core/codex-runner/agent-plugin-materializer'

describe('@ankole/agent-computer Codex Agent Plugin Skill configuration', () => {
  it('writes every member by absolute path and verifies the final state on every prepare', async () => {
    const cwd = '/workspace'
    const states = new Map([
      ['coding', true],
      ['office:docx', false],
      ['office:xlsx', true]
    ])
    const writes: Array<{ path: string; enabled: boolean }> = []
    const requests: string[] = []
    const paths = new Map([
      ['coding', '/workspace/.agents/skills/coding/SKILL.md'],
      ['office:docx', '/workspace/.codex/plugins/office/skills/docx/SKILL.md'],
      ['office:xlsx', '/workspace/.codex/plugins/office/skills/xlsx/SKILL.md']
    ])
    const client = {
      async request(method: string, params: unknown) {
        requests.push(method)
        if (method === 'skills/extraRoots/set') return {}
        if (method === 'skills/list') {
          return {
            data: [
              {
                cwd,
                errors: [],
                skills: [...states].map(([name, enabled]) => ({ name, enabled, path: paths.get(name) }))
              }
            ]
          }
        }
        if (method === 'skills/config/write') {
          const write = params as { path: string; enabled: boolean }
          writes.push(write)
          const name = [...paths].find(([, path]) => path === write.path)?.[0]
          if (!name) throw new Error(`unknown Skill path ${write.path}`)
          states.set(name, write.enabled)
          return { effectiveEnabled: write.enabled }
        }
        throw new Error(`unexpected method ${method}`)
      }
    }

    const first = await configureCodexSkills(client, cwd, ['coding'], preparedOfficePlugin())
    const second = await configureCodexSkills(client, cwd, ['coding'], preparedOfficePlugin())

    expect(first).toEqual(['coding', 'office:docx'])
    expect(second).toEqual(first)
    expect(writes).toEqual([
      { path: paths.get('office:docx')!, enabled: true },
      { path: paths.get('office:xlsx')!, enabled: false },
      { path: paths.get('office:docx')!, enabled: true },
      { path: paths.get('office:xlsx')!, enabled: false }
    ])
    expect(requests).toEqual([
      'skills/extraRoots/set',
      'skills/list',
      'skills/config/write',
      'skills/config/write',
      'skills/list',
      'skills/extraRoots/set',
      'skills/list',
      'skills/config/write',
      'skills/config/write',
      'skills/list'
    ])
  })

  it('rejects a non-absolute Skill path before writing configuration', async () => {
    const client = {
      async request(method: string) {
        if (method === 'skills/extraRoots/set') return {}
        if (method === 'skills/list') {
          return {
            data: [
              {
                cwd: '/workspace',
                errors: [],
                skills: [
                  { name: 'coding', path: '/skills/coding/SKILL.md', enabled: true },
                  { name: 'office:docx', path: 'relative/SKILL.md', enabled: true },
                  { name: 'office:xlsx', path: '/skills/xlsx/SKILL.md', enabled: true }
                ]
              }
            ]
          }
        }
        throw new Error(`unexpected method ${method}`)
      }
    }

    await expect(configureCodexSkills(client, '/workspace', ['coding'], preparedOfficePlugin())).rejects.toThrow(
      'non-absolute path'
    )
  })
})

function preparedOfficePlugin(): PreparedAgentPlugins {
  return {
    marketplaceHostPath: '/workspace/plugins/marketplace.json',
    marketplacePath: '/workspace/.agents/plugins/marketplace.json',
    marketplaceName: 'ankole-background-agent-job',
    pluginsRoot: '/workspace/plugins',
    agentPlugins: [
      {
        id: 'office',
        description: 'Office plugin',
        version: '1.0.0',
        content_hash: 'hash',
        skills: [{ catalog_name: 'docx', codex_name: 'office:docx' }],
        manifestName: 'office',
        skillsRelativePath: 'skills',
        sourceRoot: '/repo/app/library/agent-plugins/office',
        materializedRoot: '/workspace/plugins/office',
        memberSkillNames: ['docx', 'xlsx'],
        enabledSkillNames: ['docx'],
        enabledCodexSkillNames: ['office:docx']
      }
    ],
    expectedSkillNames: ['office:docx']
  }
}
