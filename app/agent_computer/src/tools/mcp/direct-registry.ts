export interface DirectStdioMCPServer {
  name: string
  namespace: string
  description: string
  transport: 'stdio'
  command: string
  args: string[]
  cwd: string
  timeoutMs: number
  enabledTools: string[]
  environmentVariables?: string[]
}

export const flintChartDirectMCPServer: Readonly<DirectStdioMCPServer> = {
  name: 'flint-chart',
  namespace: 'mcp__flint_chart',
  description:
    'Create, validate, compile, and render static charts with Flint and Vega-Lite. Use inline data.values. PNG is the default. SVG is optional. Map and Choropleth are not supported.',
  transport: 'stdio',
  command: 'bun',
  args: ['/repo/app/agent_computer/src/tools/mcp/flint-chart-server.ts'],
  cwd: '/repo/app/agent_computer',
  timeoutMs: 60_000,
  enabledTools: ['compile_chart', 'list_chart_types', 'render_chart', 'validate_chart']
}

const directMCPServers: readonly Readonly<DirectStdioMCPServer>[] = [flintChartDirectMCPServer]

/** Returns the release-defined Direct MCP servers for every execution runtime. */
export function registeredDirectMCPServers(): DirectStdioMCPServer[] {
  return directMCPServers.map(server => ({
    ...server,
    args: [...server.args],
    enabledTools: [...server.enabledTools],
    ...(server.environmentVariables ? { environmentVariables: [...server.environmentVariables] } : {})
  }))
}
