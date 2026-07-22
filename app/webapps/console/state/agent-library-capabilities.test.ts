import { describe, expect, test } from 'bun:test'
import type {
  AgentLibrarySkillCapabilityItem,
  AgentPluginCapabilityItem,
  ControlPlanePluginItem
} from '../api/generated/types.gen'
import {
  GLOBAL_LIBRARY_SCOPE,
  agentLibraryOverrideValue,
  agentLibraryScopeQuery,
  availableAgentLibraryTabs,
  filterAgentPlugins,
  filterControlPlanePlugins,
  filterSkills,
  humanizeAgentPluginID,
  localizedJSONText,
  parseAgentLibraryOverrideValue
} from './agent-library-capabilities'

const spreadsheetSkill: AgentLibrarySkillCapabilityItem = {
  agent_plugin_id: 'office',
  description: 'Create and validate spreadsheet files',
  effective_enabled: true,
  global_default_enabled: true,
  id: 'office:xlsx',
  name: 'xlsx',
  override_enabled: null,
  source_kind: 'builtin'
}

const officePlugin: AgentPluginCapabilityItem = {
  description: 'Create local office artifacts',
  effective_enabled: true,
  global_default_enabled: true,
  id: 'office',
  override_enabled: null,
  skills: [spreadsheetSkill],
  version: '1.0.0'
}

describe('Agent Library capability state', () => {
  test('shows Control Plane Plugins only in the global scope', () => {
    expect(availableAgentLibraryTabs(GLOBAL_LIBRARY_SCOPE)).toEqual([
      'agent-plugins',
      'skills',
      'control-plane-plugins'
    ])
    expect(availableAgentLibraryTabs('agent-1')).toEqual(['agent-plugins', 'skills'])
  })

  test('round-trips all three Agent override states and rejects invalid input', () => {
    expect(agentLibraryOverrideValue(null)).toBe('inherit')
    expect(agentLibraryOverrideValue(true)).toBe('enabled')
    expect(agentLibraryOverrideValue(false)).toBe('disabled')
    expect(parseAgentLibraryOverrideValue('inherit')).toBeNull()
    expect(parseAgentLibraryOverrideValue('enabled')).toBeTrue()
    expect(parseAgentLibraryOverrideValue('disabled')).toBeFalse()
    expect(() => parseAgentLibraryOverrideValue('unexpected')).toThrow('invalid Agent Library override value')
  })

  test('searches Plugin members and standalone Skill metadata', () => {
    expect(filterAgentPlugins([officePlugin], 'spreadsheet')).toEqual([officePlugin])
    expect(filterAgentPlugins([officePlugin], 'xlsx')).toEqual([officePlugin])
    expect(filterAgentPlugins([officePlugin], 'lark')).toEqual([])

    expect(filterSkills([spreadsheetSkill], 'office')).toEqual([spreadsheetSkill])
    expect(filterSkills([spreadsheetSkill], 'pdf')).toEqual([])
  })

  test('searches localized Control Plane Plugin text in the active locale', () => {
    const plugin: ControlPlanePluginItem = {
      active: true,
      configured_enabled: true,
      description: { 'en-US': 'Lark messaging', 'zh-Hans-CN': '飞书消息' },
      display_name: { 'en-US': 'Lark Adapter', 'zh-Hans-CN': '飞书适配器' },
      id: 'lark-adapter',
      restart_required: false
    }

    expect(filterControlPlanePlugins([plugin], '飞书', 'zh-Hans-CN')).toEqual([plugin])
    expect(filterControlPlanePlugins([plugin], '飞书', 'en-US')).toEqual([])
    expect(localizedJSONText(plugin.display_name, 'zh-Hans-CN')).toBe('飞书适配器')
  })

  test('preserves scope in detail links and humanizes stable IDs', () => {
    expect(agentLibraryScopeQuery('/agent-library/agent-plugins/office', GLOBAL_LIBRARY_SCOPE)).toBe(
      '/agent-library/agent-plugins/office'
    )
    expect(agentLibraryScopeQuery('/agent-library/agent-plugins/office', 'agent/a')).toBe(
      '/agent-library/agent-plugins/office?scope=agent%2Fa'
    )
    expect(humanizeAgentPluginID('deep-research')).toBe('Deep Research')
  })
})
