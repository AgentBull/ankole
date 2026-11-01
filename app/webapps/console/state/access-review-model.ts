import { computed, createModel, signal } from '@preact/signals-react'

export const AccessReviewModel = createModel(() => {
  const approvedFingerprint = signal<string>()
  const reason = signal('')
  const humanUID = signal('')
  const authorizationKind = signal<'human' | 'service'>('human')
  const hasReason = computed(() => reason.value.trim().length > 0)
  return { approvedFingerprint, reason, humanUID, authorizationKind, hasReason }
})
