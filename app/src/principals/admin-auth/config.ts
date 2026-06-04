import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'

export const AdminAuthPublicBaseUrlConfig = defineAppConfig({
  key: 'admin_auth.public_base_url',
  encrypted: false,
  schema: z.string().url(),
  description: 'Public BullX Agent base URL used to build admin OIDC redirect URIs'
})

registerAppConfigDefinitions([AdminAuthPublicBaseUrlConfig])
