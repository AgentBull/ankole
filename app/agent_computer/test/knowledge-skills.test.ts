import { describe, expect, it } from 'bun:test'
import { createHash } from 'node:crypto'
import { create } from '@bufbuild/protobuf'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeKnowledgeSkills, resolveSkillCasRoot } from '../src/skills/knowledge-skills'
import { RuntimeSkillSummarySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { jsonBytes } from '../src/fabric/envelope-proto'
import type { RPCRequester } from '../src/lanes/rpc-lane'

const skill = create(RuntimeSkillSummarySchema, { skillName: 'demo', sourceKind: 'builtin', relativePath: 'demo' })

describe('conversation-visible Skill packages', () => {
  it('uses the fenced Pod package, preserves executable files and refreshes removed files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'ankole-skill-turn-'))
    const casRoot = await mkdtemp(join(tmpdir(), 'ankole-skill-cas-'))
    const frame = { run: { session: { session_id: 'conversation:1' }, signal_id: 'signal-1', epoch: 1 } }
    let files = [
      { path: 'SKILL.md', content: Buffer.from('Skill and visible supplement.').toString('base64'), mode: 0o444 },
      { path: '..notes', content: Buffer.from('Visible package notes.').toString('base64'), mode: 0o444 },
      { path: 'scripts/run.sh', content: Buffer.from('echo current').toString('base64'), mode: 0o755 }
    ]
    const rpc = (async (method: string, payload: unknown, actualFrame: unknown) => {
      expect(method).toBe('pod.read')
      expect(payload).toMatchObject({ operation: 'skills.bundle' })
      expect(actualFrame).toEqual(frame)
      return { bodyJson: jsonBytes({ files }) }
    }) as unknown as RPCRequester
    try {
      const projected = await materializeKnowledgeSkills({ root, frame, skills: [skill], rpc, casRoot })
      expect(projected.skills[0]?.sourceKind).toBe('installed')
      expect(await readFile(join(root, 'demo/SKILL.md'), 'utf8')).toBe('Skill and visible supplement.')
      expect(await readFile(join(root, 'demo/..notes'), 'utf8')).toBe('Visible package notes.')
      expect((await stat(join(root, 'demo/scripts/run.sh'))).mode & 0o777).toBe(0o555)
      files = [{ path: 'SKILL.md', content: Buffer.from('Updated contract.').toString('base64'), mode: 0o444 }]
      await materializeKnowledgeSkills({ root, frame, skills: [skill], rpc, casRoot })
      expect(await readFile(join(root, 'demo/SKILL.md'), 'utf8')).toBe('Updated contract.')
      expect(
        await stat(join(root, 'demo/scripts/run.sh')).then(
          () => true,
          () => false
        )
      ).toBe(false)
    } finally {
      await rm(root, { recursive: true, force: true })
      await rm(casRoot, { recursive: true, force: true })
    }
  })

  it('populates the content-addressed Skill cache and hardlinks identical files across sessions with tmpdir fallback', async () => {
    const resolvedFallback = await resolveSkillCasRoot('/dev/null/unwritable-ankole-cas')
    expect(resolvedFallback).toBe(join(tmpdir(), 'ankole-skills-cas'))

    const dir = await mkdtemp(join(tmpdir(), 'ankole-skill-cas-reuse-'))
    const casRoot = join(dir, 'cas')
    const sessionOneRoot = join(dir, 'session-1')
    const sessionTwoRoot = join(dir, 'session-2')
    const frame = { run: { session: { session_id: 'conversation:cas' }, signal_id: 'signal-cas', epoch: 1 } }
    const markdownText = '# Reusable Skill\n\nShared reference payload across concurrent sessions.\n'
    const scriptText = '#!/usr/bin/env bash\necho reusable\n'
    const files = [
      { path: 'SKILL.md', content: Buffer.from(markdownText).toString('base64'), mode: 0o444 },
      { path: 'scripts/tool.sh', content: Buffer.from(scriptText).toString('base64'), mode: 0o755 }
    ]
    const rpc = (async () => ({ bodyJson: jsonBytes({ files }) })) as unknown as RPCRequester

    try {
      await materializeKnowledgeSkills({ root: sessionOneRoot, frame, skills: [skill], rpc, casRoot })
      await materializeKnowledgeSkills({ root: sessionTwoRoot, frame, skills: [skill], rpc, casRoot })

      const digest = createHash('sha256').update(markdownText).digest('hex')
      const casEntry = join(casRoot, digest.slice(0, 2), `${digest}-444`)
      const [casStat, s1Stat, s2Stat] = await Promise.all([
        stat(casEntry),
        stat(join(sessionOneRoot, 'demo/SKILL.md')),
        stat(join(sessionTwoRoot, 'demo/SKILL.md'))
      ])
      expect(await readFile(join(sessionTwoRoot, 'demo/SKILL.md'), 'utf8')).toBe(markdownText)
      expect((await stat(join(sessionTwoRoot, 'demo/scripts/tool.sh'))).mode & 0o777).toBe(0o555)
      // On the same local filesystem, both session files hardlink the immutable CAS inode!
      expect(s1Stat.ino).toBe(casStat.ino)
      expect(s2Stat.ino).toBe(casStat.ino)
      expect(casStat.nlink).toBeGreaterThanOrEqual(3)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('fetches multiple Skill bundles concurrently via Promise.all and honors explicitSha256 CAS hits', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'ankole-skill-parallel-'))
    const casRoot = join(dir, 'cas')
    const root = join(dir, 'turn')
    const frame = { run: { session: { session_id: 'conversation:parallel' }, signal_id: 'signal-p', epoch: 1 } }
    const content = 'Shared skill payload\n'
    const sha256 = createHash('sha256').update(content).digest('hex')
    const encoded = Buffer.from(content).toString('base64')
    const skills = [
      create(RuntimeSkillSummarySchema, { skillName: 'alpha', sourceKind: 'builtin', relativePath: 'alpha' }),
      create(RuntimeSkillSummarySchema, { skillName: 'beta', sourceKind: 'builtin', relativePath: 'beta' })
    ]

    let inFlight = 0
    let maxConcurrent = 0
    const rpc = (async () => {
      inFlight += 1
      maxConcurrent = Math.max(maxConcurrent, inFlight)
      await Bun.sleep(15)
      inFlight -= 1
      return { bodyJson: jsonBytes({ files: [{ path: 'SKILL.md', content: encoded, sha256, mode: 0o444 }] }) }
    }) as unknown as RPCRequester

    try {
      await materializeKnowledgeSkills({ root, frame, skills, rpc, casRoot })
      expect(maxConcurrent).toBe(2)
      expect(await readFile(join(root, 'alpha/SKILL.md'), 'utf8')).toBe(content)
      expect(await readFile(join(root, 'beta/SKILL.md'), 'utf8')).toBe(content)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })
})
