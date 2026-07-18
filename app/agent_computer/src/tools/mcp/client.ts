import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { getDefaultEnvironment, StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { CallToolResultSchema, ListToolsResultSchema, type Tool } from '@modelcontextprotocol/sdk/types.js'
import { injectableWorkerEnv } from '../computer/env'
import type { MCPServerConfig } from './config'
import { compareCodePointStrings } from './ordering'

const MAX_LIST_PAGES = 20
const MAX_TOOLS_PER_SERVER = 256
const MAX_TOOL_SCHEMA_BYTES = 64 * 1024
const MAX_CATALOG_BYTES = 512 * 1024

export interface MCPClientOperationOptions {
  workerEnv?: Record<string, string>
  signal?: AbortSignal
  timeoutMs: number
}

export type MCPListedTool = Pick<Tool, 'name' | 'description' | 'inputSchema' | 'outputSchema'>

/** Lists and validates one server's complete bounded tool catalog. */
export async function listMCPServerTools(
  server: MCPServerConfig,
  options: MCPClientOperationOptions
): Promise<MCPListedTool[]> {
  return await withEphemeralMCPClient(server, options, async (client, signal) => {
    const tools: MCPListedTool[] = []
    const names = new Set<string>()
    let cursor: string | undefined

    for (let page = 0; page < MAX_LIST_PAGES; page++) {
      const result = await client.request(
        { method: 'tools/list', params: cursor ? { cursor } : {} },
        ListToolsResultSchema,
        { signal, timeout: options.timeoutMs }
      )

      for (const tool of result.tools) {
        if (names.has(tool.name)) throw new Error(`MCP server ${server.name} returned duplicate tool ${tool.name}`)
        const schemaBytes = Buffer.byteLength(
          JSON.stringify({ inputSchema: tool.inputSchema, outputSchema: tool.outputSchema }),
          'utf8'
        )
        if (schemaBytes > MAX_TOOL_SCHEMA_BYTES) {
          throw new Error(`MCP server ${server.name} returned an oversized schema for tool ${tool.name}`)
        }
        names.add(tool.name)
        tools.push({
          name: tool.name,
          ...(tool.description ? { description: tool.description } : {}),
          inputSchema: tool.inputSchema,
          ...(tool.outputSchema ? { outputSchema: tool.outputSchema } : {})
        })
        if (tools.length > MAX_TOOLS_PER_SERVER) {
          throw new Error(`MCP server ${server.name} exceeds the ${MAX_TOOLS_PER_SERVER}-tool catalog limit`)
        }
      }

      cursor = result.nextCursor
      if (!cursor) {
        const sorted = tools.sort((left, right) => compareCodePointStrings(left.name, right.name))
        if (Buffer.byteLength(JSON.stringify(sorted), 'utf8') > MAX_CATALOG_BYTES) {
          throw new Error(`MCP server ${server.name} exceeds the ${MAX_CATALOG_BYTES}-byte catalog limit`)
        }
        return sorted
      }
    }

    throw new Error(`MCP server ${server.name} exceeds the ${MAX_LIST_PAGES}-page catalog limit`)
  })
}

/** Calls exactly one already-selected MCP tool over a fresh connection. */
export async function callMCPServerTool(
  server: MCPServerConfig,
  toolName: string,
  args: Record<string, unknown>,
  options: MCPClientOperationOptions
): Promise<unknown> {
  return await withEphemeralMCPClient(server, options, async (client, signal) => {
    return await client.request(
      { method: 'tools/call', params: { name: toolName, arguments: args } },
      CallToolResultSchema,
      { signal, timeout: options.timeoutMs }
    )
  })
}

async function withEphemeralMCPClient<T>(
  server: MCPServerConfig,
  options: MCPClientOperationOptions,
  operation: (client: Client, signal: AbortSignal) => Promise<T>
): Promise<T> {
  const budget = operationBudget(options.signal, options.timeoutMs)
  const client = new Client({ name: 'ankole-agent-computer', version: '1.0.0' })
  let operationFailed = false

  try {
    const transport = createTransport(server, options.workerEnv)
    await client.connect(transport, { signal: budget.signal, timeout: options.timeoutMs })
    return await operation(client, budget.signal)
  } catch (error) {
    operationFailed = true
    throw error
  } finally {
    budget.cleanup()
    if (operationFailed) {
      try {
        await client.close()
      } catch {
        // Preserve the transport/operation failure; close has no stronger fact.
      }
    } else {
      await client.close()
    }
  }
}

function createTransport(server: MCPServerConfig, workerEnv?: Record<string, string>) {
  if (server.transport === 'streamable_http') {
    const token = server.bearerTokenEnvVar ? resolvedWorkerEnv(workerEnv)[server.bearerTokenEnvVar] : undefined
    if (server.bearerTokenEnvVar && !token) {
      throw new Error(`MCP server ${server.name} requires WorkerEnv variable ${server.bearerTokenEnvVar}`)
    }

    return new StreamableHTTPClientTransport(
      new URL(server.url),
      token ? { requestInit: { headers: { Authorization: `Bearer ${token}` } } } : {}
    )
  }

  return new StdioClientTransport({
    command: '/bin/sh',
    args: ['-lc', server.command],
    env: { ...getDefaultEnvironment(), ...resolvedWorkerEnv(workerEnv) },
    stderr: 'ignore'
  })
}

function resolvedWorkerEnv(workerEnv?: Record<string, string>): Record<string, string> {
  return Object.fromEntries(injectableWorkerEnv(workerEnv))
}

function operationBudget(
  parent: AbortSignal | undefined,
  timeoutMs: number
): {
  signal: AbortSignal
  cleanup: () => void
} {
  const controller = new AbortController()
  const abortFromParent = () => controller.abort(parent?.reason ?? new Error('MCP operation aborted'))
  if (parent?.aborted) abortFromParent()
  else parent?.addEventListener('abort', abortFromParent, { once: true })

  const timer = setTimeout(() => controller.abort(new Error(`MCP operation timed out after ${timeoutMs}ms`)), timeoutMs)
  return {
    signal: controller.signal,
    cleanup: () => {
      clearTimeout(timer)
      parent?.removeEventListener('abort', abortFromParent)
    }
  }
}
