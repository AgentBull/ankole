import { describe, expect, it } from 'bun:test'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import type { TurnStart } from '../src/actor_bus'
import { buildAgentSystemPrompt } from '../src/prompts/system_prompt'

describe('@ankole/agent-computer prompts', () => {
  it('builds identity, soul, mission, runtime, tools, and skills in order', () => {
    const root = join(tmpdir(), `ankole-prompt-test-${Date.now()}-${Math.random()}`)
    try {
      mkdirSync(join(root, 'library-containers/skills/nano-pdf'), { recursive: true })
      writeFileSync(join(root, 'library-containers/SOUL.md'), 'Use restrained, factual judgment.')
      writeFileSync(join(root, 'library-containers/MISSION.md'), 'Handle document work end to end.')
      writeFileSync(
        join(root, 'library-containers/skills/nano-pdf/SKILL.md'),
        [
          '---',
          'name: nano-pdf',
          'description: "Edit PDF text/typos/titles via nano-pdf CLI (NL prompts)."',
          'default_enabled: true',
          'category: productivity',
          '---',
          '# nano-pdf'
        ].join('\n')
      )

      const prompt = buildAgentSystemPrompt({ workspaceRoot: root, turnStart: turnStart() })

      expect(prompt.indexOf('You are ReleaseBot')).toBeLessThan(prompt.indexOf('Use restrained'))
      expect(prompt.indexOf('Use restrained')).toBeLessThan(prompt.indexOf('Your mission is:'))
      expect(prompt.indexOf('<runtime_context>')).toBeLessThan(prompt.indexOf('<message_context_policy>'))
      expect(prompt.indexOf('<message_context_policy>')).toBeLessThan(prompt.indexOf('<tools>'))
      expect(prompt.indexOf('<tools>')).toBeLessThan(prompt.indexOf('## Skills'))
      expect(prompt).toContain('Agent UID: agent-1')
      expect(prompt).toContain('Agent display name: ReleaseBot')
      expect(prompt).toContain('Agent role: Research Analyst')
      expect(prompt).toContain('skill_view(name)')
      expect(prompt).toContain('nano-pdf')
      expect(prompt).toContain('interactive_terminal')
      expect(prompt).not.toContain('codex_delegate')
      expect(prompt).not.toContain('send_file')
      expect(prompt).not.toContain('check_back_later')
      expect(prompt).not.toContain('web_search')
      expect(prompt).not.toContain('web_extract')
      expect(prompt).not.toContain('terminal when')
      expect(prompt).not.toContain('process tool')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

function turnStart(): TurnStart {
  return {
    turn: {
      actor: {
        agent_uid: 'agent-1',
        display_name: 'ReleaseBot',
        role: 'Research Analyst',
        session_id: 'signal-channel:mock'
      },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      llm_turn_id: 'turn-1',
      revision: 0
    },
    inputs: [],
    model_ref: {
      profile: 'primary',
      provider_id: 'openrouter-main',
      model: 'z-ai/glm-5.2'
    }
  }
}
