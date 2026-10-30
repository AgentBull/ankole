import { createClientConfig } from '../common/internal-api-client'
import type { ConversationAttachment } from './api'
import { identityQuery } from './content-api'
import type { PodFileCopyResponse, PodPageCreateResponse } from './api/generated/types.gen'

export type AttachmentReceipt = { receipt: string; name: string; size: number; content_type?: string | null }
const transport = createClientConfig({}).fetch!

export function chooseLocalFile(): Promise<File | undefined> {
  return new Promise(resolve => {
    const input = document.createElement('input')
    input.type = 'file'
    input.hidden = true
    const finish = () => {
      const file = input.files?.[0]
      input.remove()
      resolve(file)
    }
    input.addEventListener('change', finish, { once: true })
    input.addEventListener('cancel', finish, { once: true })
    document.body.append(input)
    input.click()
  })
}

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

export type CustomEmoji = {
  path: string
  name: string
  sha256: string
  size: number
  content_type?: string | null
}

export type CustomEmojiLibrary = {
  custom_emojis: CustomEmoji[]
  can_upload: boolean
}

export async function customEmojiLibrary(signal?: AbortSignal): Promise<CustomEmojiLibrary> {
  const response = await transport('/api/v2/pod/metadata/custom-emojis', { method: 'GET', signal })
  return response.json()
}

export async function uploadCustomEmoji(file: File, name: string, signal?: AbortSignal): Promise<CustomEmoji> {
  const body = new FormData()
  body.set('file', file)
  body.set('name', name)
  const response = await transport('/api/v2/pod/metadata/custom-emojis', { method: 'POST', body, signal })
  return response.json()
}

export async function createFilePage(
  file: File,
  destination: { parent_id?: string; private_owner_uid?: string }
): Promise<PodPageCreateResponse> {
  const body = new FormData()
  body.set('file', file)
  for (const [key, value] of Object.entries(destination)) if (value) body.set(key, value)
  const response = await transport('/api/v2/pod/file-pages', { method: 'POST', body })
  return response.json()
}

export function conversationAttachmentURL(conversationID: string, messageID: string, path: string, download = false) {
  const query = new URLSearchParams({ path, ...(download ? { download: 'true' } : {}), ...identityQuery() })
  return `/api/v2/pod/conversations/${encodeURIComponent(conversationID)}/attachments/${encodeURIComponent(messageID)}?${query}`
}

export function restoreConversationFiles(
  conversationID: string,
  messageID: string,
  attachments: ConversationAttachment[]
): Promise<File[]> {
  return Promise.all(
    attachments.map(async attachment => {
      const response = await transport(conversationAttachmentURL(conversationID, messageID, attachment.path), {
        method: 'GET'
      })
      const bytes = await response.blob()
      return new File([bytes], attachment.name, { type: attachment.content_type || attachment.mime_type || bytes.type })
    })
  )
}
