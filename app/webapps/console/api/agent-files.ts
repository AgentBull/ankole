import { client } from './v2/generated/client.gen'
import { formDataBodySerializer } from './v2/generated/client'

export function uploadDriveFile(tenantID: string, parentID: string, name: string, file: File) {
  return client.post<unknown, unknown>({
    ...formDataBodySerializer,
    url: '/api/v2/drive/{tenant_id}/uploads',
    path: { tenant_id: tenantID },
    body: { parent_id: parentID, name, file },
    headers: { 'Content-Type': null, accept: 'application/json' }
  })
}

export function downloadDriveFile(tenantID: string, nodeID: string) {
  return client.get<Blob, unknown>({
    url: '/api/v2/drive/{tenant_id}/nodes/{id}/content',
    path: { tenant_id: tenantID, id: nodeID },
    parseAs: 'blob',
    headers: { accept: 'application/json' }
  })
}
