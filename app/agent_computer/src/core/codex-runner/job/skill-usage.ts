import { compareCodePointStrings } from '../../../common/ordering'
import type { BackgroundAgentJobAttemptHistoryEntry } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { MCPServerConfig } from '../../../tools/mcp'
import type { ThreadItem } from '../generated/protocol/v2/ThreadItem'

/**
 * Maps Worker-injected commands to their owning Skill because tool calls do
 * not observe these commands.
 */
const runtimeInjectedSkillCommands = new Map([['browser', ['ankole-browser']]])

export class CodexSkillUsageTracker {
  readonly availableSkillNames: ReadonlySet<string>
  readonly usedSkillNames = new Set<string>()

  private readonly disabledSkillNames = new Set<string>()
  private readonly notifiedDisabledSkillNames = new Set<string>()
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

  disable(skillNames: string[]): void {
    for (const name of skillNames) {
      if (this.availableSkillNames.has(name)) this.disabledSkillNames.add(name)
    }
  }

  recordLoaded(name: string): string[] {
    return this.markUsed([name])
  }

  observeItem(value: unknown): string[] {
    if (!value || typeof value !== 'object') return []
    const item = value as ThreadItem
    if (item.type === 'mcpToolCall') {
      const owner = this.skillByMCPServer.get(item.server)
      return owner ? this.markUsed([owner]) : []
    }

    if (item.type !== 'commandExecution') return []
    return this.markUsed(
      [...runtimeInjectedSkillCommands.entries()].flatMap(([name, commands]) =>
        commands.some(command => boundedTokenReference(item.command, command)) ? [name] : []
      )
    )
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

function boundedTokenReference(text: string, token: string): boolean {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`(^|[^\\p{L}\\p{N}_-])${escaped}(?=$|[^\\p{L}\\p{N}_-])`, 'u').test(text)
}
