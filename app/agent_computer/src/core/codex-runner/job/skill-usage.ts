import { compareCodePointStrings } from '../../../common/ordering'
import { relative, resolve } from 'node:path'
import type { BackgroundAgentJobAttemptHistoryEntry } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { MCPServerConfig } from '../../../tools/mcp'
import type { ThreadItem } from '../generated/protocol/v2/ThreadItem'

export type DiscoveredCodexSkill = {
  name: string
  invocationNames?: string[]
  path: string
  enabled: boolean
}

/**
 * Maps Worker-injected commands to their owning Skill because path and MCP
 * evidence cannot observe these commands. Add a registry only if another
 * injected CLI needs attribution.
 */
const runtimeInjectedSkillCommands = new Map([['browser', ['ankole-browser']]])

export class CodexSkillUsageTracker {
  readonly availableSkillNames: ReadonlySet<string>
  readonly usedSkillNames = new Set<string>()

  private readonly disabledSkillNames = new Set<string>()
  private readonly notifiedDisabledSkillNames = new Set<string>()
  private readonly skillPaths = new Map<string, string[]>()
  private readonly skillInvocationNames = new Map<string, string[]>()
  private readonly skillByMCPServer = new Map<string, string>()

  constructor(input: {
    availableSkillNames: string[]
    mcpServers: MCPServerConfig[]
    attemptHistory?: BackgroundAgentJobAttemptHistoryEntry[]
  }) {
    this.availableSkillNames = new Set(input.availableSkillNames)
    for (const server of input.mcpServers) {
      const owners = server.sourceSkills.filter(name => this.availableSkillNames.has(name))
      if (owners.length === 1) this.skillByMCPServer.set(server.name, owners[0]!)
    }
    for (const attempt of input.attemptHistory ?? []) {
      for (const name of attempt.usedSkillNames) {
        if (this.availableSkillNames.has(name)) this.usedSkillNames.add(name)
      }
    }
  }

  setDiscoveredSkills(cwd: string, skills: DiscoveredCodexSkill[]): void {
    for (const skill of skills) {
      if (!skill.enabled || !this.availableSkillNames.has(skill.name)) continue
      const absolute = resolve(skill.path)
      const projectRelative = relative(cwd, absolute)
      this.skillPaths.set(
        skill.name,
        [absolute, projectRelative, `.agents/skills/${skill.name}`].filter(path => path && path !== '.')
      )
      this.skillInvocationNames.set(skill.name, [skill.name, ...(skill.invocationNames ?? [])])
    }
  }

  disable(skillNames: string[]): void {
    for (const name of skillNames) {
      if (this.availableSkillNames.has(name)) this.disabledSkillNames.add(name)
    }
  }

  observeInput(text: string): string[] {
    return this.markUsed(
      [...this.availableSkillNames].filter(name =>
        (this.skillInvocationNames.get(name) ?? [name]).some(invocationName =>
          explicitSkillReference(text, invocationName)
        )
      )
    )
  }

  observeItem(value: unknown): string[] {
    if (!value || typeof value !== 'object') return []
    const item = value as ThreadItem
    if (item.type === 'mcpToolCall') {
      const owner = this.skillByMCPServer.get(item.server)
      return owner ? this.markUsed([owner]) : []
    }

    const evidence = itemPathEvidence(item)
    if (!evidence) return []
    return this.markUsed([
      ...[...this.skillPaths.entries()].flatMap(([name, paths]) =>
        paths.some(path => pathReference(evidence, path)) ? [name] : []
      ),
      ...(item.type === 'commandExecution'
        ? [...runtimeInjectedSkillCommands.entries()].flatMap(([name, commands]) =>
            commands.some(command => boundedTokenReference(item.command, command)) ? [name] : []
          )
        : [])
    ])
  }

  pendingDisabledNotices(): string[] {
    return [...this.disabledSkillNames]
      .filter(name => this.usedSkillNames.has(name) && !this.notifiedDisabledSkillNames.has(name))
      .sort(compareCodePointStrings)
  }

  markNotified(name: string): void {
    if (this.disabledSkillNames.has(name) && this.usedSkillNames.has(name)) {
      this.notifiedDisabledSkillNames.add(name)
    }
  }

  private markUsed(skillNames: string[]): string[] {
    const added: string[] = []
    for (const name of skillNames.sort(compareCodePointStrings)) {
      if (!this.availableSkillNames.has(name) || this.usedSkillNames.has(name)) continue
      this.usedSkillNames.add(name)
      added.push(name)
    }
    return added
  }
}

export function skillDisabledNotice(name: string): string {
  return `Skill \`${name}\` has been disabled for this Agent. Do not use it again in this Job. Continue with the remaining capabilities. If no valid alternative exists, explain the blocker.`
}

export function explicitSkillReference(text: string, name: string): boolean {
  return boundedTokenReference(text, `$${name}`)
}

function boundedTokenReference(text: string, token: string): boolean {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(^|[^\\p{L}\\p{N}_-])${escaped}(?=$|[^\\p{L}\\p{N}_-])`, 'u').test(text)
}

function itemPathEvidence(item: ThreadItem): string | undefined {
  if (item.type === 'commandExecution') return `${item.cwd}\n${item.command}`
  if (item.type === 'imageView') return item.path
  return undefined
}

function pathReference(evidence: string, path: string): boolean {
  if (!path || !evidence.includes(path)) return false
  const index = evidence.indexOf(path)
  const after = evidence[index + path.length]
  return after === undefined || after === '/' || /[\s'"`:;,)]/.test(after)
}
