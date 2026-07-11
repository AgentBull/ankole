import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { scanInstalledSkills } from '../src/skills/installed_skills'

describe('@ankole/agent-computer installed skill scanner', () => {
  it('parses valid installed skills and skips excluded or symlinked files', async () => {
    const root = tempRoot('installed-skill-valid')
    try {
      const agentUID = 'agent-valid'
      const skillDir = join(root, agentUID, 'agent-notes')
      mkdirSync(join(skillDir, 'references'), { recursive: true })
      mkdirSync(join(skillDir, 'target'), { recursive: true })
      mkdirSync(join(skillDir, 'node_modules'), { recursive: true })
      writeFileSync(join(skillDir, 'target', 'ignored.txt'), 'ignore')
      writeFileSync(join(skillDir, 'node_modules', 'ignored.txt'), 'ignore')
      writeFileSync(join(skillDir, 'references', 'usage.md'), '# Usage\n')
      writeSkill(skillDir, {
        name: 'agent-notes',
        description: 'Agent installed notes.',
        extra: ['tags:', '  - notes', '  - custom', 'category: custom', 'long_running: true']
      })

      try {
        symlinkSync(join(skillDir, 'references', 'usage.md'), join(skillDir, 'linked.md'))
      } catch {
        // Some host filesystems disallow symlink creation; the core scan still runs.
      }

      const scan = await scanInstalledSkills(root, agentUID)
      expect(scan.observations).toHaveLength(1)
      expect(scan.observations[0]).toMatchObject({
        skill_name: 'agent-notes',
        relative_path: 'agent-notes',
        description: 'Agent installed notes.',
        default_enabled: true,
        file_count: 2
      })
      expect(scan.observations[0]!.metadata).toMatchObject({
        category: 'custom',
        tags: ['notes', 'custom'],
        long_running: true
      })
      expect(scan.observations[0]!.xxh3_128).toMatch(/^[a-f0-9]{32}$/)

      const secondScan = await scanInstalledSkills(root, agentUID)
      expect(secondScan.fingerprint).toBe(scan.fingerprint)
      expect(secondScan.observations[0]!.xxh3_128).toBe(scan.observations[0]!.xxh3_128)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skips missing, mismatched, and symlinked skill directories without failing the scan', async () => {
    const root = tempRoot('installed-skill-invalid')
    try {
      const agentUID = 'agent-invalid'
      const agentRoot = join(root, agentUID)
      mkdirSync(join(agentRoot, 'no-skill-md'), { recursive: true })
      writeSkill(join(agentRoot, 'mismatch'), {
        name: 'other-name',
        description: 'Mismatched name.'
      })

      try {
        symlinkSync(join(agentRoot, 'mismatch'), join(agentRoot, 'linked-skill'), 'dir')
      } catch {
        // Symlink diagnostics are covered when the host permits them.
      }

      const scan = await scanInstalledSkills(root, agentUID)
      expect(scan.observations).toEqual([])
      expect(scan.diagnostics.some(diagnostic => diagnostic.code === 'skill_name_directory_mismatch')).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('returns an empty authoritative scan when the agent directory is absent', async () => {
    const root = tempRoot('installed-skill-empty')
    try {
      const scan = await scanInstalledSkills(root, 'agent-empty')
      expect(scan.observations).toEqual([])
      expect(scan.fingerprint).toMatch(/^[a-f0-9]{32}$/)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('reports the per-skill file limit once', async () => {
    const root = tempRoot('installed-skill-file-limit')
    try {
      const agentUID = 'agent-file-limit'
      const skillDir = join(root, agentUID, 'agent-notes')
      writeSkill(skillDir, {
        name: 'agent-notes',
        description: 'Agent installed notes.'
      })
      mkdirSync(join(skillDir, 'references'), { recursive: true })
      for (let index = 0; index < 520; index += 1) {
        writeFileSync(join(skillDir, 'references', `file-${index}.md`), `# File ${index}\n`)
      }

      const scan = await scanInstalledSkills(root, agentUID)
      expect(scan.observations[0]?.file_count).toBe(512)
      expect(
        scan.diagnostics.filter(diagnostic => diagnostic.code === 'installed_skill_file_limit_reached')
      ).toHaveLength(1)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function tempRoot(name: string): string {
  const root = join(tmpdir(), `ankole-${name}-${Date.now()}-${Math.random()}`)
  mkdirSync(root, { recursive: true })
  return root
}

function writeSkill(
  dir: string,
  input: {
    name: string
    description: string
    extra?: string[]
  }
): void {
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, 'SKILL.md'),
    [
      '---',
      `name: ${input.name}`,
      `description: ${input.description}`,
      'default_enabled: true',
      ...(input.extra ?? []),
      '---',
      '',
      `# ${input.name}`,
      ''
    ].join('\n')
  )
}
