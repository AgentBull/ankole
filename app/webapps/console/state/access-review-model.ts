import { computed, createModel, signal } from '@preact/signals-react'

export const AccessReviewModel = createModel(() => {
  const reason = signal('')
  const humanUID = signal('')
  const authorizationKind = signal<'human' | 'service'>('human')
  const hasReason = computed(() => reason.value.trim().length > 0)
  return { reason, humanUID, authorizationKind, hasReason }
})
