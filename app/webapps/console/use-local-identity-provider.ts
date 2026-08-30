import { useQuery } from '@tanstack/react-query'
import { ankoleWebIdentityProviderControllerIndexOptions } from './api/generated/@tanstack/react-query.gen'

/**
 * Tells whether the built-in local password provider is enabled. Local
 * account management (create, reset, edit) is only offered then. While the
 * list loads, the answer is "not enabled": the controls stay hidden and
 * appear once the load confirms the provider.
 */
export function useLocalIdentityProvider(): { enabled: boolean } {
  const providers = useQuery(ankoleWebIdentityProviderControllerIndexOptions())
  const enabled = (providers.data?.identity_providers ?? []).some(
    provider => provider.adapter_id === 'local' && provider.enabled
  )

  return { enabled }
}
