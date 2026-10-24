import { createModel, signal } from '@preact/signals-react'

export const JoinSpaceModel = createModel(() => ({ slug: signal(''), invitation: signal('') }))

export function invitationToken(input: string, origin: string): string {
  const raw = input.trim()
  const encoded = raw.includes('/join/') ? (new URL(raw, origin).pathname.split('/join/')[1] ?? '') : raw
  return decodeURIComponent(encoded)
}
