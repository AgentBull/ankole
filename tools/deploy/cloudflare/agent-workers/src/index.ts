import { AgentWorker } from './agent-worker'
import { registryName, type Env } from './env'
import { handle, type WorkerApi } from './http'
import { Registry } from './registry'

export { AgentWorker, Registry }
export { DirectoryBackupGateway } from '@cloudflare/sandbox'

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    const registry = env.REGISTRY.get(env.REGISTRY.idFromName(registryName))
    return handle(request, {
      token: env.ANKOLE_ADAPTER_TOKEN,
      worker: agentUid => env.AGENT_WORKER.get(env.AGENT_WORKER.idFromName(agentUid)) as unknown as WorkerApi,
      list: providerId => registry.list(providerId)
    })
  }
} satisfies ExportedHandler<Env>
