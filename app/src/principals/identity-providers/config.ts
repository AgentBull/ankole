import {
  bullxExternalIdentityNamespaceIdPattern,
  bullxExternalIdentityNamespaceIdPatternSource
} from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'
import {
  defineAppConfig,
  defineAppConfigPattern,
  registerAppConfigDefinitions,
  registerAppConfigPatterns
} from '@/config/app-configure'
import { appConfigJsonRecordSchema } from '@/config/json-value-schema'

export const reservedIdentityProviderIds = new Set(['active'])
export const identityProviderIdSchema = z
  .string()
  .regex(bullxExternalIdentityNamespaceIdPattern)
  .refine(providerId => !reservedIdentityProviderIds.has(providerId), {
    message: 'reserved identity providerId'
  })

export const identityProviderActivationSchema = z
  .object({
    /**
     * Installation-local external identity namespace, for example `lark-main`.
     *
     * This is also the `provider` namespace stored on login/directory-produced
     * `principal_external_identities` rows. It is not the adapter id, not a
     * bot/channel id, and not a direct relation from a chat adapter to this
     * identity-provider runtime.
     */
    providerId: identityProviderIdSchema,
    adapter: z.string().min(1),
    enabled: z.boolean().default(true)
  })
  .strict()

export type IdentityProviderActivation = z.infer<typeof identityProviderActivationSchema>

export const ActiveIdentityProvidersConfig = defineAppConfig({
  key: 'identity_providers.active',
  encrypted: false,
  /**
   * The host chooses which identity provider instances are active. Plugins
   * advertise adapter factories; the provider config key is owned by the host
   * and keyed only by the globally unique provider id.
   */
  schema: z.array(identityProviderActivationSchema).superRefine((activations, context) => {
    const seen = new Set<string>()
    activations.forEach((activation, index) => {
      if (!seen.has(activation.providerId)) {
        seen.add(activation.providerId)
        return
      }

      context.addIssue({
        code: 'custom',
        message: `duplicate identity providerId: ${activation.providerId}`,
        path: [index, 'providerId']
      })
    })
  }),
  defaultValue: [],
  description: 'Identity provider instances started by the BullX Agent host process'
})

export const IdentityProviderConfigPattern = defineAppConfigPattern({
  id: 'identity_providers.provider_config',
  keyPattern: new RegExp(`^identity_providers\\.(?!active$)${bullxExternalIdentityNamespaceIdPatternSource}$`),
  encrypted: true,
  schema: appConfigJsonRecordSchema,
  defaultValue: {},
  description: 'Encrypted identity provider configuration keyed by globally unique providerId'
})

registerAppConfigDefinitions([ActiveIdentityProvidersConfig])
registerAppConfigPatterns([IdentityProviderConfigPattern])

export function identityProviderConfigKey(providerId: string): string {
  const normalizedProviderId = identityProviderIdSchema.parse(providerId)
  return `identity_providers.${normalizedProviderId}`
}
