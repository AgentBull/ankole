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

// `active` is reserved because the list of active providers lives at the config
// key `identity_providers.active`. Allowing a provider with that id would let a
// per-provider config key collide with the activation list key itself.
export const reservedIdentityProviderIds = new Set(['active'])
export const identityProviderIdSchema = z
  .string()
  .regex(bullxExternalIdentityNamespaceIdPattern)
  .refine(providerId => !reservedIdentityProviderIds.has(providerId), {
    message: 'reserved identity providerId'
  })

/**
 * One entry in the host's "which providers are active" list.
 *
 * Pairs an installation-local provider id with the plugin adapter that drives
 * it, plus a soft `enabled` flag so an operator can pause a provider without
 * deleting its (encrypted) configuration.
 */
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
    // Provider ids must be unique across the list: each id maps to exactly one
    // per-provider config key and one external-identity `provider` namespace, so
    // a duplicate would make those bindings ambiguous. The issue is attached to
    // the offending array index for a precise validation error.
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

/**
 * Per-provider configuration stored at `identity_providers.<providerId>`.
 *
 * Encrypted because adapter config typically holds provider app secrets. The key
 * pattern uses a `(?!active$)` lookahead so the activation list key is never
 * matched as if it were a provider's own config.
 */
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

/**
 * Builds the app-config key holding a provider's encrypted configuration.
 *
 * Re-validates the id through the schema so a caller cannot construct a key for a
 * reserved or malformed provider id, which would otherwise read or write the
 * wrong config row.
 */
export function identityProviderConfigKey(providerId: string): string {
  const normalizedProviderId = identityProviderIdSchema.parse(providerId)
  return `identity_providers.${normalizedProviderId}`
}
