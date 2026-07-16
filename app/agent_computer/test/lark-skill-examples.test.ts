import { describe, expect, it } from 'bun:test'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  discoverSkillNamesByExecutionProfile,
  extractLarkCommandExamples,
  findUnscopedExecutableLarkCommands,
  larkSkillExecutionProfile,
  validateLarkCommandExample,
  type CommandRunner,
  type LarkCommandExample
} from '../src/validation/lark-skill-examples'

describe('Lark skill example validation', () => {
  it('discovers validation targets from Skill execution profile metadata', async () => {
    const root = await mkdtemp(join(tmpdir(), 'ankole-lark-skills-'))

    try {
      await writeSkill(root, 'custom-lark-skill', larkSkillExecutionProfile)
      await writeSkill(root, 'ordinary-skill', 'ordinary-shell')

      expect(await discoverSkillNamesByExecutionProfile(root, larkSkillExecutionProfile)).toEqual(['custom-lark-skill'])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('extracts only executable bot examples and classifies command shapes', () => {
    const examples = extractLarkCommandExamples(
      [
        'lark-cli --version',
        'lark-cli calendar events search_event --calendar-id cal --as bot --format json',
        'lark-cli contact +get-user --user-id ou_xxx --as bot --format json',
        'lark-cli api GET "/open-apis/minutes/v1/minutes/<token>/transcript" --as bot --format json',
        'lark-cli approval approvals get --as user --format json'
      ].join('\n'),
      'reference.md'
    )

    expect(
      examples.map(example => ({ kind: example.kind, service: example.service, resource: example.resource }))
    ).toEqual([
      { kind: 'typed', service: 'calendar', resource: 'events' },
      { kind: 'shortcut', service: 'contact', resource: '+get-user' },
      { kind: 'raw-api', service: 'api', resource: 'GET' }
    ])
  })

  it('rejects executable commands that rely on an implicit identity', () => {
    const commands = findUnscopedExecutableLarkCommands(
      [
        'lark-cli --version',
        'lark-cli schema calendar.events.search_event',
        'lark-cli calendar events search_event --help',
        'lark-cli approval approvals get --format json'
      ].join('\n')
    )

    expect(commands).toEqual([{ line: 4, command: 'lark-cli approval approvals get --format json' }])
  })

  it('requires typed methods to exist and declare bot access', () => {
    const example = typedExample()

    expect(validateLarkCommandExample(example, schemaRunner(['bot', 'user']))).toEqual([])
    expect(validateLarkCommandExample(example, schemaRunner(['user']))).toContain(
      'schema calendar.events.search_event does not declare bot access'
    )
    expect(
      validateLarkCommandExample(example, () => ({ exitCode: 2, output: 'not available in current identity mode' }))
    ).toEqual([
      'schema calendar.events.search_event is unavailable in strict bot mode: not available in current identity mode'
    ])
  })

  it('rejects user-only and missing shortcuts under strict bot mode', () => {
    const userOnly = shortcutExample('+search-user')
    const missing = shortcutExample('+missing')

    expect(
      validateLarkCommandExample(userOnly, () => ({
        exitCode: 2,
        output: 'denied by strict_mode policy (reason_code identity_not_supported)'
      }))
    ).toEqual(['shortcut contact +search-user rejects bot identity'])

    expect(
      validateLarkCommandExample(missing, () => ({ exitCode: 2, output: 'unknown subcommand "+missing"' }))
    ).toEqual(['shortcut contact +missing does not exist'])
  })

  it('allows only the audited Minutes transcript raw API path', () => {
    const run: CommandRunner = () => ({ exitCode: 0, output: '{"as": "bot"}' })

    expect(validateLarkCommandExample(rawAPIExample('/open-apis/minutes/v1/minutes/<token>/transcript'), run)).toEqual(
      []
    )
    expect(validateLarkCommandExample(rawAPIExample('/open-apis/approval/v4/approvals/<code>'), run)).toEqual([
      'raw API path is not in the audited bot allowlist: GET /open-apis/approval/v4/approvals/<code>'
    ])
  })
})

async function writeSkill(root: string, name: string, executionProfile: string): Promise<void> {
  const directory = join(root, name)
  await mkdir(directory)
  await writeFile(
    join(directory, 'SKILL.md'),
    `---\nname: ${name}\ndescription: Test Skill.\nexecution_profile: ${executionProfile}\n---\n\n# Test\n`
  )
}

function typedExample(): LarkCommandExample {
  return {
    file: 'calendar.md',
    line: 1,
    command: 'lark-cli calendar events search_event --as bot --format json',
    service: 'calendar',
    resource: 'events',
    method: 'search_event',
    kind: 'typed'
  }
}

function shortcutExample(resource: string): LarkCommandExample {
  return {
    file: 'contact.md',
    line: 1,
    command: `lark-cli contact ${resource} --as bot --format json`,
    service: 'contact',
    resource,
    kind: 'shortcut'
  }
}

function schemaRunner(accessTokens: string[]): CommandRunner {
  return () => ({
    exitCode: 0,
    output: JSON.stringify({ _meta: { access_tokens: accessTokens } })
  })
}

function rawAPIExample(path: string): LarkCommandExample {
  return {
    file: 'raw.md',
    line: 1,
    command: `lark-cli api GET "${path}" --as bot --format json`,
    service: 'api',
    resource: 'GET',
    method: `"${path}"`,
    kind: 'raw-api'
  }
}
