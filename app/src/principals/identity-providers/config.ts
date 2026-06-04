import { bullxExternalIdentityProviderIdPattern } from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'

export const identityProviderIdSchema = z.string().regex(bullxExternalIdentityProviderIdPattern)

export const identityProviderActivationSchema = z
  .object({
    /**
     * Installation-local external identity namespace, for example `lark-main`.
     *
     * This is the `provider` stored on `principal_external_identities`. It is not
     * the adapter id, not a bot/channel id, and not a direct relation from a chat
     * adapter to this identity-provider runtime.
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
   * The host chooses which identity provider instances are active. Plugins only
   * advertise adapter factories and config patterns; they do not decide whether
   * a provider participates in admin login or directory sync.
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

registerAppConfigDefinitions([ActiveIdentityProvidersConfig])

export function identityProviderConfigKey(adapter: string, providerId: string): string {
  const normalizedProviderId = identityProviderIdSchema.parse(providerId)
  return `identity_providers.${adapter}.${normalizedProviderId}`
}
