import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { getDefaultEnvironment, StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import {
  CallToolResultSchema,
  ListToolsResultSchema,
  type CallToolResult,
  type Tool
} from '@modelcontextprotocol/sdk/types.js'
import type { DirectStdioMCPServer } from './direct-registry'
import { compareCodePointStrings } from './ordering'

const maxListPages = 20
const maxToolsPerServer = 256
const maxToolSchemaBytes = 64 * 1024
const maxCatalogBytes = 512 * 1024
const maxCallArgumentBytes = 2 * 1024 * 1024
const maxStdioMessageBytes = 72 * 1024 * 1024

export type DirectMCPListedTool = Pick<
  Tool,
  'name' | 'title' | 'description' | 'inputSchema' | 'outputSchema' | 'annotations' | '_meta'
>

export interface DirectMCPServerCatalog {
  instructions?: string
  tools: DirectMCPListedTool[]
}

export interface DirectMCPClientOptions {
  workerEnv?: Record<string, string>
  signal?: AbortSignal
}

/** Lists one release-defined Direct MCP server through a fresh stdio process. */
export async function listDirectMCPServerCatalog(
  server: DirectStdioMCPServer,
  options: DirectMCPClientOptions = {}
): Promise<DirectMCPServerCatalog> {
  return await withDirectMCPClient(server, options, async (client, signal) => {
    const tools: DirectMCPListedTool[] = []
    const names = new Set<string>()
    let cursor: string | undefined

    for (let page = 0; page < maxListPages; page += 1) {
      const result = await client.request(
        { method: 'tools/list', params: cursor ? { cursor } : {} },
        ListToolsResultSchema,
        { signal, timeout: server.timeoutMs }
      )

      for (const tool of result.tools) {
        if (names.has(tool.name)) continue
        const schemaBytes = Buffer.byteLength(
          JSON.stringify({ inputSchema: tool.inputSchema, outputSchema: tool.outputSchema }),
          'utf8'
        )
        if (schemaBytes > maxToolSchemaBytes) {
          throw new Error(`Direct MCP server ${server.name} returned an oversized schema for tool ${tool.name}`)
        }
        names.add(tool.name)
        tools.push({
          name: tool.name,
          ...(tool.title ? { title: tool.title } : {}),
          ...(tool.description ? { description: tool.description } : {}),
          inputSchema: tool.inputSchema,
          ...(tool.outputSchema ? { outputSchema: tool.outputSchema } : {}),
          ...(tool.annotations ? { annotations: tool.annotations } : {}),
          ...(tool._meta ? { _meta: tool._meta } : {})
        })
        if (tools.length > maxToolsPerServer) {
          throw new Error(`Direct MCP server ${server.name} exceeds the ${maxToolsPerServer}-tool catalog limit`)
        }
      }

      cursor = result.nextCursor
      if (!cursor) {
        const catalog: DirectMCPServerCatalog = {
          ...(client.getInstructions() !== undefined ? { instructions: client.getInstructions() } : {}),
          tools: tools.sort((left, right) => compareCodePointStrings(left.name, right.name))
        }
        if (Buffer.byteLength(JSON.stringify(catalog), 'utf8') > maxCatalogBytes) {
          throw new Error(`Direct MCP server ${server.name} exceeds the ${maxCatalogBytes}-byte catalog limit`)
        }
        return catalog
      }
    }

    throw new Error(`Direct MCP server ${server.name} exceeds the ${maxListPages}-page catalog limit`)
  })
}

/** Calls one selected Direct MCP tool through a fresh stdio process. */
export async function callDirectMCPServerTool(
  server: DirectStdioMCPServer,
  toolName: string,
  args: Record<string, unknown>,
  options: DirectMCPClientOptions = {}
): Promise<CallToolResult> {
  const argumentBytes = Buffer.byteLength(JSON.stringify(args), 'utf8')
  if (argumentBytes > maxCallArgumentBytes) {
    throw new Error(`Direct MCP tool arguments exceed ${maxCallArgumentBytes} bytes; aggregate or downsample the data`)
  }

  return await withDirectMCPClient(server, options, async (client, signal) => {
    return await client.request(
      { method: 'tools/call', params: { name: toolName, arguments: args } },
      CallToolResultSchema,
      { signal, timeout: server.timeoutMs }
    )
  })
}

async function withDirectMCPClient<T>(
  server: DirectStdioMCPServer,
  options: DirectMCPClientOptions,
  operation: (client: Client, signal: AbortSignal) => Promise<T>
): Promise<T> {
  const budget = operationBudget(options.signal, server.timeoutMs)
  const client = new Client({ name: 'ankole-agent-computer', version: '1.0.0' })
  let failed = false

  try {
    await client.connect(createTransport(server, options.workerEnv), {
      signal: budget.signal,
      timeout: server.timeoutMs
    })
    return await operation(client, budget.signal)
  } catch (error) {
    failed = true
    throw error
  } finally {
    budget.cleanup()
    if (failed) await client.close().catch(() => undefined)
    else await client.close()
  }
}

function createTransport(server: DirectStdioMCPServer, workerEnv?: Record<string, string>): StdioClientTransport {
  const env = getDefaultEnvironment()
  for (const name of server.environmentVariables ?? []) {
    const value = workerEnv?.[name]
    if (!value) throw new Error(`Direct MCP server ${server.name} requires WorkerEnv variable ${name}`)
    env[name] = value
  }

  return new StdioClientTransport({
    command: server.command,
    args: server.args,
    cwd: server.cwd,
    env,
    stderr: 'ignore',
    maxBufferSize: maxStdioMessageBytes
  })
}

function operationBudget(
  parent: AbortSignal | undefined,
  timeoutMs: number
): { signal: AbortSignal; cleanup: () => void } {
  const controller = new AbortController()
  const abortFromParent = () => controller.abort(parent?.reason ?? new Error('Direct MCP operation aborted'))
  if (parent?.aborted) abortFromParent()
  else parent?.addEventListener('abort', abortFromParent, { once: true })

  const timer = setTimeout(
    () => controller.abort(new Error(`Direct MCP operation timed out after ${timeoutMs}ms`)),
    timeoutMs
  )
  return {
    signal: controller.signal,
    cleanup: () => {
      clearTimeout(timer)
      parent?.removeEventListener('abort', abortFromParent)
    }
  }
}
