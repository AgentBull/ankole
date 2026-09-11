import { computed, createModel, signal } from '@preact/signals-react'

export const AccessReviewModel = createModel(() => {
  const approvedFingerprint = signal<string>()
  const reason = signal('')
  const confirmed = signal(false)
  const identityVerified = signal(false)
  const humanUID = signal('')
  const authorizationKind = signal<'human' | 'service'>('human')
  const hasReason = computed(() => reason.value.trim().length > 0)
  return { approvedFingerprint, reason, confirmed, identityVerified, humanUID, authorizationKind, hasReason }
})
