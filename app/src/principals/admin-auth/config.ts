import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'

/**
 * Persisted public base URL the admin OIDC flow uses to build redirect URIs.
 *
 * The OIDC redirect URI must be byte-stable and must match what is registered
 * at the identity provider, but the request origin seen by the process can be a
 * private address behind a reverse proxy. Storing the operator-declared public
 * URL lets callback URIs stay correct regardless of how the request reached the
 * server. Not encrypted because it is a public address, not a secret.
 */
export const AdminAuthPublicBaseUrlConfig = defineAppConfig({
  key: 'admin_auth.public_base_url',
  encrypted: false,
  schema: z.string().url(),
  description: 'Public BullX Agent base URL used to build admin OIDC redirect URIs'
})

registerAppConfigDefinitions([AdminAuthPublicBaseUrlConfig])
