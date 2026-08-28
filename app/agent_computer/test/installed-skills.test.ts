import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { scanInstalledSkills } from '../src/skills/installed_skills'

describe('@ankole/agent-computer installed skill scanner', () => {
  it('parses complete YAML frontmatter without traversing skill contents', async () => {
    const root = tempRoot('installed-skill-valid')
    try {
      const skillDir = join(root, 'agent-notes')
      mkdirSync(join(skillDir, 'references'), { recursive: true })
      mkdirSync(join(skillDir, 'target'), { recursive: true })
      mkdirSync(join(skillDir, 'node_modules'), { recursive: true })
      writeFileSync(join(skillDir, 'target', 'ignored.txt'), 'ignore')
      writeFileSync(join(skillDir, 'node_modules', 'ignored.txt'), 'ignore')
      writeFileSync(join(skillDir, 'references', 'usage.md'), '# Usage\n')
      writeSkill(skillDir, {
        name: 'agent-notes',
        description: '>-\n  Agent installed notes.',
        extra: ['tags:', '  - "notes:custom"', '  - custom', 'category: custom', 'ankole-runtime: background_job']
      })

      try {
        symlinkSync(join(skillDir, 'references', 'usage.md'), join(skillDir, 'linked.md'))
      } catch {
        // Some host filesystems disallow symlink creation; the core scan still runs.
      }

      const scan = await scanInstalledSkills(root)
      expect(scan.observations).toHaveLength(1)
      expect(scan.observations[0]).toMatchObject({
        skill_name: 'agent-notes',
        description: 'Agent installed notes.',
        default_enabled: true,
        tags: ['notes:custom', 'custom'],
        category: 'custom',
        ankole_runtime: 'background_job'
      })

      const secondScan = await scanInstalledSkills(root)
      expect(secondScan.snapshot).toBe(scan.snapshot)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('skips missing, mismatched, and symlinked skill directories without failing the scan', async () => {
    const root = tempRoot('installed-skill-invalid')
    try {
      const agentRoot = root
      mkdirSync(join(agentRoot, 'no-skill-md'), { recursive: true })
      writeSkill(join(agentRoot, 'mismatch'), {
        name: 'other-name',
        description: 'Mismatched name.'
      })
      writeSkill(join(agentRoot, 'invalid-runtime'), {
        name: 'invalid-runtime',
        description: 'Invalid runtime.',
        extra: ['ankole-runtime: worker']
      })
      try {
        symlinkSync(join(agentRoot, 'mismatch'), join(agentRoot, 'linked-skill'), 'dir')
      } catch {
        // Symlink diagnostics are covered when the host permits them.
      }

      const scan = await scanInstalledSkills(root)
      expect(scan.observations).toEqual([])
      expect(scan.diagnostics.some(diagnostic => diagnostic.code === 'skill_name_directory_mismatch')).toBe(true)
      expect(scan.diagnostics.some(diagnostic => diagnostic.code === 'invalid_ankole_runtime')).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('returns an empty authoritative scan when the agent directory is absent', async () => {
    const root = tempRoot('installed-skill-empty')
    try {
      rmSync(root, { recursive: true, force: true })
      const scan = await scanInstalledSkills(root)
      expect(scan.observations).toEqual([])
      expect(scan.snapshot).toBe('[]')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('reports invalid YAML and omits the malformed observation', async () => {
    const root = tempRoot('installed-skill-invalid-yaml')
    try {
      const skillDir = join(root, 'agent-notes')
      mkdirSync(skillDir, { recursive: true })
      writeFileSync(join(skillDir, 'SKILL.md'), '---\nname: agent-notes\ntags: [unterminated\n---\n')

      const scan = await scanInstalledSkills(root)
      expect(scan.observations).toEqual([])
      expect(scan.diagnostics.filter(diagnostic => diagnostic.code === 'invalid_skill_frontmatter')).toHaveLength(1)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('fails instead of replacing the registry with a truncated scan', async () => {
    const root = tempRoot('installed-skill-count-limit')
    try {
      for (let index = 0; index <= 200; index += 1) {
        const name = `skill-${String(index).padStart(3, '0')}`
        writeSkill(join(root, name), { name, description: `Installed Skill ${index}.` })
      }

      await expect(scanInstalledSkills(root)).rejects.toThrow('installed skill count exceeds 200')
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
