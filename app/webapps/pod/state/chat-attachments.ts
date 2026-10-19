import { batch, computed, createModel, signal } from '@preact/signals-react'
import { uploadAttachment } from '../api'

export type AttachmentDraft = {
  id: string
  file: File
  url: string
  state: 'uploading' | 'ready' | 'failed'
  receipt?: string
  error?: unknown
}
export type AttachmentSnapshot = { attachments: string[]; attachmentIDs: string[] }
type Upload = typeof uploadAttachment

/** The conversation draft owns selected Files and their upload lifetime. */
export const ChatAttachments = createModel((upload: Upload = uploadAttachment) => {
  const files = signal<AttachmentDraft[]>([])
  const requests = new Map<string, AbortController>()
  const hasFiles = computed(() => files.value.length > 0)
  const canSend = computed(() => files.value.every(file => file.state === 'ready'))

  const update = (id: string, patch: Partial<AttachmentDraft>) => {
    files.value = files.value.map(file => (file.id === id ? { ...file, ...patch } : file))
  }
  const start = async (item: AttachmentDraft) => {
    requests.get(item.id)?.abort()
    const request = new AbortController()
    requests.set(item.id, request)
    update(item.id, { state: 'uploading', error: undefined })
    try {
      const result = await upload(item.file, item.id, request.signal)
      if (requests.get(item.id) === request) update(item.id, { state: 'ready', receipt: result.receipt })
    } catch (error) {
      if (requests.get(item.id) === request) update(item.id, { state: 'failed', error })
    } finally {
      if (requests.get(item.id) === request) requests.delete(item.id)
    }
  }
  const remove = (id: string) => {
    requests.get(id)?.abort()
    requests.delete(id)
    const item = files.peek().find(file => file.id === id)
    if (item) URL.revokeObjectURL(item.url)
    files.value = files.peek().filter(file => file.id !== id)
  }

  return {
    files,
    hasFiles,
    canSend,
    add(selected: Iterable<File>) {
      const added = [...selected].map(file => ({
        id: crypto.randomUUID(),
        file,
        url: URL.createObjectURL(file),
        state: 'uploading' as const
      }))
      files.value = [...files.peek(), ...added]
      for (const item of added) void start(item)
    },
    retry(id: string) {
      const item = files.peek().find(file => file.id === id)
      if (item) void start(item)
    },
    remove,
    capture(): AttachmentSnapshot {
      if (!canSend.peek()) throw new Error('Attachments are not ready')
      return { attachments: files.peek().map(file => file.receipt!), attachmentIDs: files.peek().map(file => file.id) }
    },
    accepted(ids: string[] = []) {
      batch(() => {
        for (const id of ids) remove(id)
      })
    },
    expired(ids: string[] = []) {
      batch(() => {
        for (const id of ids) update(id, { state: 'failed', receipt: undefined })
      })
    },
    dispose() {
      for (const file of files.peek()) remove(file.id)
    }
  }
})
export type ChatAttachments = InstanceType<typeof ChatAttachments>

export function isPreviewImage(type: string | undefined): boolean {
  return !!type && ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/bmp'].includes(type)
}
