import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { Type } from 'typebox'
import { buildTool } from './build-tool'

const minimalDef = {
  name: 'minimal',
  label: 'Minimal',
  description: 'test tool',
  parameters: Type.Object({}),
  async execute() {
    return { content: [], details: {} }
  }
}

describe('buildTool fail-closed defaults', () => {
  it('fills conservative defaults while allowing explicit tool declarations to opt out', () => {
    const tool = buildTool(minimalDef)
    expect(tool.executionMode).toBe('sequential')
    expect(tool.isReadOnly).toBe(false)
    expect(tool.isDestructive).toBe(true)

    const explicitlySafe = buildTool({
      ...minimalDef,
      executionMode: 'parallel',
      isReadOnly: true,
      isDestructive: false
    })
    expect(explicitlySafe.executionMode).toBe('parallel')
    expect(explicitlySafe.isReadOnly).toBe(true)
    expect(explicitlySafe.isDestructive).toBe(false)
  })
})
