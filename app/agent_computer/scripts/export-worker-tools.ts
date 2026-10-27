import { zodToJSONSchema } from '../src/core/tool-schema'
import type { WorkerAgentTool } from '../src/core/types'
import { computerToolsForContext } from '../src/tools/computer'

export function workerToolDeclarations(tools: WorkerAgentTool[]): Array<Record<string, unknown>> {
  return tools.map(tool => {
    if (typeof tool.retrySafe !== 'boolean') throw new Error(`${tool.name} must declare retrySafe`)
    const shared = {
      name: tool.name,
      description: tool.description,
      execution_mode: tool.executionMode,
      read_only: tool.isReadOnly,
      destructive: tool.isDestructive,
      retry_safe: tool.retrySafe
    }
    return tool.inputFormat
      ? { ...shared, type: 'custom', format: tool.inputFormat }
      : { ...shared, type: 'function', parameters: zodToJSONSchema(tool.schema) }
  })
}

export const workerToolsPath = new URL('../../kernel/proto/ankole/runtime_fabric/v1/worker_tools.json', import.meta.url)

if (import.meta.main) {
  // Schema export never accesses a computer or runtime connection.
  const tools = computerToolsForContext({
    agentHome: '/workspace',
    workspaceRoot: '/workspace/sessions/1',
    computer: {
      runCommand: async () => {
        throw new Error('schema export cannot access the computer')
      },
      readFileWindow: async () => {
        throw new Error('schema export cannot access the computer')
      },
      readFileBytes: async () => {
        throw new Error('schema export cannot access the computer')
      }
    }
  })
  const output = `${JSON.stringify(workerToolDeclarations(tools), null, 2)}\n`
  if (process.argv.includes('--check')) {
    if ((await Bun.file(workerToolsPath).text()) !== output) throw new Error('worker_tools.json is out of date')
  } else {
    await Bun.write(workerToolsPath, output)
  }
}
