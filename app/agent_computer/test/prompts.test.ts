import { describe, expect, it } from 'bun:test'
import { rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import type { TurnStart } from '../src/actor_lane'
import {
  buildCompactionHistoryUserPrompt,
  COMPACTION_FOCUS_INSTRUCTIONS,
  SUMMARIZATION_SYSTEM_PROMPT
} from '../src/prompts/compression-prompt'
import { buildAgentSystemPrompt } from '../src/prompts/system_prompt'

describe('@ankole/agent-computer prompts', () => {
  it('builds identity, soul, mission, runtime, tools, and skills in order', () => {
    const root = join(tmpdir(), `ankole-prompt-test-${Date.now()}-${Math.random()}`)
    try {
      const start = turnStart()

      const prompt = buildAgentSystemPrompt({
        workspaceRoot: root,
        turnStart: start,
        agentProfile: {
          request_id: 'agent-profile-1',
          agent_uid: 'agent-1',
          display_name: 'ReleaseBot',
          role: 'Research Analyst'
        },
        runtimeContext: {
          request_id: 'turn-context-1',
          agent_uid: 'agent-1',
          session_id: 'signal-channel:mock',
          turn: start.turn,
          soul: 'Use restrained, factual judgment.',
          mission: 'Handle document work end to end.',
          skills: [
            {
              skill_name: 'nano-pdf',
              description: 'Edit PDF text/typos/titles via nano-pdf CLI (NL prompts).',
              category: 'productivity',
              metadata: {}
            }
          ],
          conversation: { messages: [] }
        }
      })

      expect(prompt.indexOf('You are ReleaseBot')).toBeLessThan(prompt.indexOf('Use restrained'))
      expect(prompt.indexOf('Use restrained')).toBeLessThan(prompt.indexOf('Your mission is:'))
      expect(prompt.indexOf('<runtime_context>')).toBeLessThan(prompt.indexOf('<agent_environment_info_policy>'))
      expect(prompt.indexOf('<agent_environment_info_policy>')).toBeLessThan(prompt.indexOf('<tools>'))
      expect(prompt.indexOf('<tools>')).toBeLessThan(prompt.indexOf('## Skills'))
      expect(prompt).toContain('Agent UID: agent-1')
      expect(prompt).toContain('Agent display name: ReleaseBot')
      expect(prompt).toContain('Agent role: Research Analyst')
      expect(prompt).toContain('skill_view(name)')
      expect(prompt).toContain('nano-pdf')
      expect(prompt).toContain('interactive_terminal')
      expect(prompt).not.toContain('TigerFS')
      expect(prompt).not.toContain('library-containers')
      expect(prompt).not.toContain('AGENT_APPEND.md')
      expect(prompt).not.toContain('PostgreSQL client')
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

  it('keeps compression prompt sections and analysis focus in the worker prompt builder', () => {
    const prompt = buildCompactionHistoryUserPrompt({
      conversationText: '[User]: fix /compress\n\n[Assistant]: working on it',
      customInstructions: COMPACTION_FOCUS_INSTRUCTIONS,
      previousChatHistory: 'Existing compressed chat history.'
    })

    expect(SUMMARIZATION_SYSTEM_PROMPT).toContain('Do NOT continue the conversation')
    expect(prompt).toContain('<conversation>')
    expect(prompt).toContain('<previous_chat_history>')
    expect(prompt).toContain('Existing compressed chat history.')
    expect(prompt).toContain('## Active Task')
    expect(prompt).toContain('## Constraints & Preferences')
    expect(prompt).toContain('## Completed Actions')
    expect(prompt).toContain('## Active State')
    expect(prompt).toContain('## In Progress')
    expect(prompt).toContain('## Blocked')
    expect(prompt).toContain('## Key Decisions')
    expect(prompt).toContain('## Resolved Questions')
    expect(prompt).toContain('## Pending User Asks')
    expect(prompt).toContain('## Remaining Work')
    expect(prompt).toContain('## Critical Context')
    expect(prompt).toContain('<analysis>')
    expect(prompt).toContain('Preserve verbatim')
  })
})

function turnStart(): TurnStart {
  return {
    turn: {
      actor: {
        agent_uid: 'agent-1',
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
