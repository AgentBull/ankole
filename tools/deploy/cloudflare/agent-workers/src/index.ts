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
      worker: agentUid => {
        const stub = env.AGENT_WORKER.get(env.AGENT_WORKER.idFromName(agentUid))
        return {
          create: input => stub.create(input),
          remove: (providerId, generation, req) => stub.remove(providerId, generation, req),
          state: providerId => stub.state(providerId),
          images: () => stub.images(),
          restore: authorization => stub.restore(authorization),
          backup: authorization => stub.backup(authorization),
          storageRef: providerId => stub.storageRef(providerId),
          deleteStorage: (uid, providerId) => stub.deleteStorage(uid, providerId)
        } satisfies WorkerApi
      },
      list: providerId => registry.list(providerId)
    })
  }
} satisfies ExportedHandler<Env>
