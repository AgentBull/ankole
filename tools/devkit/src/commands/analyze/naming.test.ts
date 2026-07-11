import { describe, expect, test } from 'bun:test'
import {
  CANONICAL_INITIALISMS,
  canonicalCamelIdentifier,
  canonicalPascalIdentifier,
  canonicalSourcePath
} from './naming-policy'
import { findLexicalNamingViolations, findTypeScriptNamingViolations } from './naming'

describe('naming policy', () => {
  test('preserves canonical initialisms inside PascalCase identifiers', () => {
    for (const initialism of CANONICAL_INITIALISMS) {
      const titleCase = `${initialism[0]}${initialism.slice(1).toLowerCase()}`
      expect(canonicalPascalIdentifier(`${titleCase}Client`)).toBe(`${initialism}Client`)
    }

    expect(canonicalPascalIdentifier('RpcRequest')).toBe('RPCRequest')
    expect(canonicalPascalIdentifier('AIGatewayApiKeyResponse')).toBe('AIGatewayAPIKeyResponse')
    expect(canonicalPascalIdentifier('JsonRpcMessage')).toBe('JSONRPCMessage')
    expect(canonicalPascalIdentifier('HttpSseTransport')).toBe('HTTPSSETransport')
    expect(canonicalPascalIdentifier('HTTPSUrl')).toBe('HTTPSURL')
    expect(canonicalPascalIdentifier('AiClient')).toBe('AIClient')
    expect(canonicalPascalIdentifier('ImGateway')).toBe('IMGateway')
    expect(canonicalPascalIdentifier('SqlStore')).toBe('SQLStore')
    expect(canonicalPascalIdentifier('OpenaiResponses')).toBe('OpenAIResponses')
    expect(canonicalPascalIdentifier('ResponseCreateWsRequest')).toBe('ResponseCreateWebSocketRequest')
  })

  test('keeps the leading word lower camel while preserving later initialisms', () => {
    expect(canonicalCamelIdentifier('rpcClient')).toBe('rpcClient')
    expect(canonicalCamelIdentifier('workerRpcRequest')).toBe('workerRPCRequest')
    expect(canonicalCamelIdentifier('aiGatewayApiKey')).toBe('aiGatewayAPIKey')
    expect(canonicalCamelIdentifier('agentUid')).toBe('agentUID')
    expect(canonicalCamelIdentifier('parseJsonRpcLine')).toBe('parseJSONRPCLine')
  })

  test('uses domain word boundaries in source paths', () => {
    expect(canonicalSourcePath('app/agent_computer/src/core/ai_gateway_transport.ts')).toBe(
      'app/agent_computer/src/core/ai_gateway_transport.ts'
    )
    expect(canonicalSourcePath('app/agent_computer/src/lanes/rpc_lane.ts')).toBe(
      'app/agent_computer/src/lanes/rpc_lane.ts'
    )
  })

  test('reports noncanonical owned identifiers but accepts an aliased external import', () => {
    const source = [
      "import type { JsonObject as JSONObject } from '@pleisto/active-support'",
      'export type RpcRequest = JSONObject',
      'export function handleWorkerRpcRequest(request: RpcRequest): void {}'
    ].join('\n')

    expect(findTypeScriptNamingViolations('fixture.ts', source)).toEqual([
      { actual: 'RpcRequest', expected: 'RPCRequest', file: 'fixture.ts', line: 2 },
      { actual: 'handleWorkerRpcRequest', expected: 'handleWorkerRPCRequest', file: 'fixture.ts', line: 3 }
    ])
  })

  test('does not claim third-party member names as owned declarations', () => {
    const source = [
      'const element = document.getElementById("root")',
      'const { webSocketDebuggerUrl: webSocketDebuggerURL } = remoteTarget'
    ].join('\n')

    expect(findTypeScriptNamingViolations('fixture.ts', source)).toEqual([])
  })

  test('accepts canonical aliases for external Elixir and Rust names', () => {
    const source = [
      'alias OpenApiSpex, as: OpenAPISpex',
      'use uuid::Uuid as UUID;',
      'use proto::envelope::Body::RpcRequest as RPCRequestBody;'
    ].join('\n')

    expect(findLexicalNamingViolations('fixture.rs', source)).toEqual([])
  })
})
