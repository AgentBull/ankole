import { createClientConfig } from '../common/internal-api-client'
import type { PodFileCopyResponse } from './api/generated/types.gen'

export type AttachmentReceipt = { receipt: string; name: string; size: number; content_type?: string | null }
const transport = createClientConfig({}).fetch!

export async function uploadAttachment(file: File, fileID: string, signal: AbortSignal): Promise<AttachmentReceipt> {
  const body = new FormData()
  body.set('file', file)
  body.set('fileID', fileID)
  const response = await transport('/api/v2/pod/attachments', { method: 'POST', body, signal })
  return response.json()
}

export async function uploadFile(
  id: string,
  file: File,
  role: 'file' | 'asset' | 'attachment',
  revision?: number
): Promise<PodFileCopyResponse> {
  const body = new FormData()
  body.set('file', file)
  body.set('role', role)
  if (revision !== undefined) body.set('base_revision', String(revision))
  const response = await transport(`/api/v2/pod/pages/${encodeURIComponent(id)}/files`, { method: 'POST', body })
  return response.json()
}
