import { expect, test } from 'bun:test'
import type {
  Inputs as GithubInputs,
  Outputs as GithubOutputs,
  Tool as GithubTool
} from '@ankole/applet-sdk/toolkits/github'
import type { Toolkit, ToolkitInputs, ToolkitOutputs, ToolkitTool } from '@ankole/applet-sdk/toolkits'

test('per-platform and barrel toolkit type entrypoints expose matching contracts', () => {
  const tool: GithubTool = 'actions_get_run'
  const barrelTool: ToolkitTool<'github'> = tool
  const toolkit: Toolkit = 'github'

  type SameInput = GithubInputs['actions_get_run'] extends ToolkitInputs['github']['actions_get_run'] ? true : false
  type SameOutput = GithubOutputs['actions_get_run'] extends ToolkitOutputs['github']['actions_get_run'] ? true : false

  const inputMatches: SameInput = true
  const outputMatches: SameOutput = true

  expect(barrelTool).toBe('actions_get_run')
  expect(toolkit).toBe('github')
  expect(inputMatches).toBe(true)
  expect(outputMatches).toBe(true)
})
