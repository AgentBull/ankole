import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import type { AgentTool } from '../../src/core'
import { createDirectMCPTools } from '../../src/tools/mcp'
import { flintChartDirectMCPServer } from '../../src/tools/mcp/direct-registry'

describe('release-defined Flint Direct MCP integration', () => {
  let root: string | undefined

  afterEach(() => {
    if (root) rmSync(root, { recursive: true, force: true })
    root = undefined
  })

  it('projects the static surface and produces PNG, SVG-capable, and Vega-Lite artifacts', async () => {
    root = mkdtempSync(join(tmpdir(), 'ankole-flint-direct-mcp-'))
    const tools = await createDirectMCPTools({ artifactRoot: root })

    expect(tools.map(tool => tool.name)).toEqual([
      'compile_chart',
      'list_chart_types',
      'render_chart',
      'validate_chart'
    ])
    expect(tools.every(tool => tool.namespace === 'mcp__flint_chart' && tool.deferLoading === true)).toBe(true)
    expect(tools.every(tool => tool.allowedCallers?.join(',') === 'direct,programmatic')).toBe(true)
    expect(tools.some(tool => tool.name === 'create_chart_view')).toBe(false)

    const listResult = await execute(tools, 'list_chart_types', { backend: 'vegalite' })
    const chartTypes = JSON.parse(textContent(listResult)).flatMap(
      (catalog: { chartTypes: Array<{ chartType: string }> }) => catalog.chartTypes.map(entry => entry.chartType)
    )
    expect(chartTypes).not.toContain('Map')
    expect(chartTypes).not.toContain('Choropleth')

    await expect(
      execute(tools, 'validate_chart', {
        ...chartInput('Map'),
        backend: 'vegalite'
      })
    ).rejects.toThrow('Flint Map and Choropleth charts are disabled in Ankole')

    const renderResult = await execute(tools, 'render_chart', {
      ...chartInput('Bar Chart'),
      backend: 'vegalite'
    })
    const pngPath = artifactPaths(renderResult).find(path => path.endsWith('.png'))
    expect(pngPath).toBeDefined()
    expect(readFileSync(pngPath!).subarray(0, 8)).toEqual(Buffer.from('89504e470d0a1a0a', 'hex'))
    expect(renderResult.content.some(part => part.type === 'image' && part.mimeType === 'image/png')).toBe(true)
    expect(textContent(renderResult)).toContain('vegalite · png')

    const svgResult = await execute(tools, 'render_chart', {
      ...chartInput('Bar Chart'),
      backend: 'vegalite',
      format: 'svg'
    })
    const svgPath = artifactPaths(svgResult).find(path => path.endsWith('.svg'))
    expect(svgPath).toBeDefined()
    expect(readFileSync(svgPath!, 'utf8').trimStart()).toStartWith('<svg')
    expect(textContent(svgResult)).toContain('vegalite · svg')

    const compileResult = await execute(tools, 'compile_chart', {
      ...chartInput('Bar Chart'),
      backend: 'vegalite'
    })
    const specPath = artifactPaths(compileResult).find(path => path.endsWith('.vl.json'))
    expect(specPath).toBeDefined()
    const compiled = JSON.parse(readFileSync(specPath!, 'utf8'))
    expect(compiled.mark).toBe('bar')
    expect(compiled.data).toBeObject()
    expect(compiled.spec).toBeUndefined()
  })

  it('removes the MCP App, prompt, and resource surfaces at the policy proxy', async () => {
    const server = flintChartDirectMCPServer
    const client = new Client({ name: 'ankole-flint-policy-test', version: '1.0.0' })
    await client.connect(
      new StdioClientTransport({
        command: server.command,
        args: server.args,
        cwd: server.cwd,
        stderr: 'ignore'
      })
    )

    try {
      const capabilities = client.getServerCapabilities()
      expect(capabilities?.tools).toBeObject()
      expect(capabilities?.prompts).toBeUndefined()
      expect(capabilities?.resources).toBeUndefined()
      await expect(client.callTool({ name: 'create_chart_view', arguments: {} })).rejects.toThrow(
        'Flint MCP method is not available in Ankole'
      )
    } finally {
      await client.close()
    }
  })
})

function chartInput(chartType: string): Record<string, unknown> {
  return {
    data: {
      values: [
        { region: 'North', revenue: 120 },
        { region: 'South', revenue: 90 },
        { region: 'East', revenue: 150 }
      ]
    },
    semantic_types: { region: 'Category', revenue: 'Quantity' },
    chart_spec: {
      chartType,
      encodings: { x: { field: 'region' }, y: { field: 'revenue' } },
      baseSize: { width: 360, height: 240 }
    }
  }
}

async function execute(tools: AgentTool[], name: string, args: Record<string, unknown>) {
  const tool = tools.find(candidate => candidate.name === name)
  if (!tool) throw new Error(`missing Direct MCP tool ${name}`)
  return await tool.execute(`test-${name}`, args)
}

function textContent(result: Awaited<ReturnType<typeof execute>>): string {
  return result.content.flatMap(part => (part.type === 'text' ? [part.text] : [])).join('\n')
}

function artifactPaths(result: Awaited<ReturnType<typeof execute>>): string[] {
  const details = result.details as { artifacts?: unknown }
  return Array.isArray(details.artifacts)
    ? details.artifacts.filter((path): path is string => typeof path === 'string')
    : []
}
