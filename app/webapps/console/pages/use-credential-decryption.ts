import { useMutation } from '@tanstack/react-query'
import { useCallback, useEffect, useRef, useState } from 'react'
import { decryptAiGatewayCredentialMutation } from '../api/v2-site/generated/@tanstack/react-query.gen'
import { decryptedCredentialFieldText } from '../state/provider-settings'

type CredentialFieldRevealRequest = {
  providerID: string
  credentialID: string
  fieldKey: string
  targetKey?: string
  onDecrypted: (value: string | undefined) => void
  onError?: (error: unknown) => void
}

/**
 * Coordinates per-field credential decryption using each call's own
 * `mutateAsync` promise rather than `MutationObserver.mutate` callbacks, so
 * rapid or concurrent reveals across multiple fields never drop earlier
 * results or loading indicators.
 */
export function useCredentialDecryption() {
  const mutation = useMutation({
    meta: { invalidates: false },
    ...decryptAiGatewayCredentialMutation(),
    gcTime: 0
  })
  const mutationRef = useRef(mutation)
  mutationRef.current = mutation

  const activeRequestsRef = useRef<Record<string, symbol>>({})
  const [revealingTargets, setRevealingTargets] = useState<Record<string, true>>({})
  const [error, setError] = useState<unknown>()

  useEffect(
    () => () => {
      activeRequestsRef.current = {}
    },
    []
  )

  const cancelTarget = useCallback((targetKey: string) => {
    delete activeRequestsRef.current[targetKey]
    setRevealingTargets(current => {
      if (!current[targetKey]) return current
      const next = { ...current }
      delete next[targetKey]
      return next
    })
  }, [])

  const cancelPrefix = useCallback((prefix: string) => {
    for (const key of Object.keys(activeRequestsRef.current)) {
      if (key.startsWith(prefix)) delete activeRequestsRef.current[key]
    }
    setRevealingTargets(current => {
      const entries = Object.entries(current).filter(([key]) => !key.startsWith(prefix))
      return entries.length === Object.keys(current).length ? current : Object.fromEntries(entries)
    })
  }, [])

  const reset = useCallback(() => {
    activeRequestsRef.current = {}
    setRevealingTargets(current => (Object.keys(current).length === 0 ? current : {}))
    setError(undefined)
    mutationRef.current.reset()
  }, [])

  const reveal = useCallback(
    async ({
      providerID,
      credentialID,
      fieldKey,
      targetKey = fieldKey,
      onDecrypted,
      onError
    }: CredentialFieldRevealRequest) => {
      const request = Symbol()
      activeRequestsRef.current[targetKey] = request
      setError(undefined)
      setRevealingTargets(current => (current[targetKey] ? current : { ...current, [targetKey]: true }))
      try {
        const response = await mutationRef.current.mutateAsync({
          path: { provider_id: providerID, credential_id: credentialID }
        })
        if (activeRequestsRef.current[targetKey] !== request) return
        onDecrypted(decryptedCredentialFieldText(response.decrypted_credential.values, fieldKey))
      } catch (err) {
        if (activeRequestsRef.current[targetKey] !== request) return
        setError(err)
        onError?.(err)
      } finally {
        if (activeRequestsRef.current[targetKey] === request) {
          delete activeRequestsRef.current[targetKey]
          setRevealingTargets(current => {
            if (!current[targetKey]) return current
            const next = { ...current }
            delete next[targetKey]
            return next
          })
        }
      }
    },
    []
  )

  const isRevealing = useCallback((targetKey: string) => Boolean(revealingTargets[targetKey]), [revealingTargets])

  return {
    error,
    isRevealing,
    reveal,
    cancelTarget,
    cancelPrefix,
    reset
  }
}
