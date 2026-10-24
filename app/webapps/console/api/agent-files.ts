import { client } from './v2/generated/client.gen'
import { formDataBodySerializer } from './v2/generated/client'

export function uploadAgentFile(agentUID: string, path: string, file: File) {
  return client.post<unknown, unknown>({
    ...formDataBodySerializer,
    url: '/api/v2/agents/{agent_uid}/files',
    path: { agent_uid: agentUID },
    body: { path, file },
    headers: { 'Content-Type': null, accept: 'application/json' }
  })
}

export function downloadAgentFile(agentUID: string, path: string) {
  return client.get<Blob, unknown>({
    url: '/api/v2/agents/{agent_uid}/files/content',
    path: { agent_uid: agentUID },
    query: { path },
    parseAs: 'blob',
    headers: { accept: 'application/json' }
  })
}
