import { useQuery } from '@tanstack/react-query'
import { ankoleWebIdentityProviderControllerIndexOptions } from './api/generated/@tanstack/react-query.gen'

/**
 * Tells whether the built-in local password provider is enabled. Local
 * account management (create, reset, edit) is only offered then. While the
 * list loads, the answer is "not enabled", so the controls appear instead of
 * disappearing.
 */
export function useLocalIdentityProvider(): { enabled: boolean; isLoading: boolean } {
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const enabled = (providers.data?.identity_providers ?? []).some(
    provider => provider.adapter_id === 'local' && provider.enabled
  )

  return { enabled, isLoading: providers.isLoading }
}
