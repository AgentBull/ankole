import type {
  LlmProviderCredentialRejected,
  LlmProviderCredentialRequest,
  LlmProviderCredentialResponse,
  TurnStart,
  TurnSteerUpdate
} from './actor_bus'
import { runLlmTurnHandlers } from './llm_runtime/text_turn_loop'

type ParentRequest =
  | {
      type: 'turn_start'
      turn_start: TurnStart
      workspace_root: string
      correlation_id?: string
    }
  | {
      type: 'credential_response'
      response: LlmProviderCredentialResponse | LlmProviderCredentialRejected
    }
  | {
      type: 'steer'
      turn: TurnSteerUpdate['turn']
      inputs: TurnSteerUpdate['inputs']
    }

const stdin = process.stdin
const stdout = process.stdout
const decoder = new TextDecoder()
let pendingInput = ''
const queuedLines: string[] = []
const steeringUpdates: TurnSteerUpdate[] = []
const credentialWaiters = new Map<
  string,
  {
    resolve: (response: LlmProviderCredentialResponse | LlmProviderCredentialRejected) => void
    reject: (error: Error) => void
  }
>()

stdin.on('data', chunk => {
  pendingInput += typeof chunk === 'string' ? chunk : decoder.decode(chunk)
  drainInputLines()
})

try {
  const start = (await readParentRequest()) as ParentRequest
  if (start.type !== 'turn_start') {
    throw new Error(`expected turn_start, got ${start.type}`)
  }

  const proposal = await runLlmTurnHandlers(start.turn_start, {
    workspaceRoot: start.workspace_root,
    requestCredential,
    pollSteering
  })

  writeProtocol({ type: 'final', proposal, turn: start.turn_start.turn })
  process.exit(0)
} catch (error) {
  writeProtocol({
    type: 'error',
    error: error instanceof Error ? error.message : String(error)
  })
  process.exit(1)
}

async function requestCredential(
  request: LlmProviderCredentialRequest
): Promise<LlmProviderCredentialResponse | LlmProviderCredentialRejected> {
  writeProtocol({ type: 'credential_request', request })

  return await new Promise<LlmProviderCredentialResponse | LlmProviderCredentialRejected>((resolve, reject) => {
    credentialWaiters.set(request.request_id, { resolve, reject })
    void waitForCredentialResponse(request.request_id).catch(error => {
      credentialWaiters.delete(request.request_id)
      reject(error instanceof Error ? error : new Error(String(error)))
    })
  })
}

async function waitForCredentialResponse(requestId: string): Promise<void> {
  while (credentialWaiters.has(requestId)) {
    const message = (await readParentRequest()) as ParentRequest
    if (message.type === 'steer') {
      steeringUpdates.push({ turn: message.turn, inputs: message.inputs })
      continue
    }

    if (message.type !== 'credential_response') {
      throw new Error(`unexpected parent message while waiting for credential: ${message.type}`)
    }

    const response = message.response
    if (response.request_id !== requestId) {
      continue
    }

    const waiter = credentialWaiters.get(requestId)
    credentialWaiters.delete(requestId)
    waiter?.resolve(response)
  }
}

function pollSteering(): TurnSteerUpdate[] {
  drainQueuedSteeringMessages()
  return steeringUpdates.splice(0)
}

function drainQueuedSteeringMessages(): void {
  let index = 0
  while (index < queuedLines.length) {
    const message = JSON.parse(queuedLines[index]) as ParentRequest
    if (message.type === 'steer') {
      queuedLines.splice(index, 1)
      steeringUpdates.push({ turn: message.turn, inputs: message.inputs })
      continue
    }
    index += 1
  }
}

function writeProtocol(value: unknown): void {
  stdout.write(`${JSON.stringify(value)}\n`)
}

async function readParentRequest(): Promise<ParentRequest> {
  while (true) {
    const queued = queuedLines.shift()
    if (queued !== undefined) {
      return JSON.parse(queued) as ParentRequest
    }

    if (stdin.readableEnded) {
      throw new Error('parent protocol stream ended')
    }

    await onceReadable()
  }
}

function drainInputLines(): void {
  while (true) {
    const newline = pendingInput.indexOf('\n')
    if (newline === -1) {
      return
    }

    const line = pendingInput.slice(0, newline).trim()
    pendingInput = pendingInput.slice(newline + 1)
    if (line) {
      queuedLines.push(line)
    }
  }
}

function onceReadable(): Promise<void> {
  return new Promise(resolve => {
    const onData = () => {
      stdin.off('data', onData)
      resolve()
    }
    stdin.on('data', onData)
  })
}
