import { bullxExternalIdentityNamespaceIdPattern } from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'

export const larkChannelConfigSchema = z
  .object({
    appId: z.string().min(1),
    appSecret: z.string().min(1),
    /**
     * Connection realm for both API base URLs and the shared long connection.
     * Chat and identity realtime sync can share one app only when this matches.
     */
    domain: z.enum(['feishu', 'lark']).default('feishu'),
    group_message_mode: z.enum(['addressed_only', 'observe_all', 'may_intervene']).default('observe_all'),
    /**
     * Namespace used when this chat channel records Lark `user_id` subjects.
     * Channels installed in the same Lark tenant can use the same namespace so
     * BullX recognizes the same human across those chat channels.
     */
    platformSubjectNamespace: z.string().regex(bullxExternalIdentityNamespaceIdPattern).optional(),
    /**
     * @deprecated Old channel configs used this key before the Lark setup UI made
     * the platform-subject namespace explicit. Keep read compatibility so stored
     * encrypted configs do not have to be migrated immediately.
     */
    platformProviderId: z.string().regex(bullxExternalIdentityNamespaceIdPattern).optional(),
    userName: z.string().min(1).optional(),
    /** Stream the agent's answer into a live CardKit card (vs a single post). */
    streamingEnabled: z.boolean().default(true),
    /** Min interval between streaming-card updates, ms (throttle). */
    streamUpdateIntervalMs: z.number().int().min(0).default(800),
    /** Flush a streaming-card update once this many new chars accumulate. */
    streamBufferThreshold: z.number().int().min(1).default(24)
  })
  .strict()
  .superRefine((config, context) => {
    const namespace = config.platformSubjectNamespace ?? config.platformProviderId
    if (!namespace) {
      context.addIssue({
        code: 'custom',
        path: ['platformSubjectNamespace'],
        message: 'platformSubjectNamespace is required'
      })
      return
    }

    if (
      config.platformSubjectNamespace &&
      config.platformProviderId &&
      config.platformSubjectNamespace !== config.platformProviderId
    ) {
      context.addIssue({
        code: 'custom',
        path: ['platformProviderId'],
        message: 'legacy platformProviderId must match platformSubjectNamespace when both are provided'
      })
    }
  })
  .transform(config => ({
    appId: config.appId,
    appSecret: config.appSecret,
    domain: config.domain,
    group_message_mode: config.group_message_mode,
    platformSubjectNamespace: config.platformSubjectNamespace ?? config.platformProviderId!,
    userName: config.userName,
    streamingEnabled: config.streamingEnabled,
    streamUpdateIntervalMs: config.streamUpdateIntervalMs,
    streamBufferThreshold: config.streamBufferThreshold
  }))

export const larkIdentityProviderConfigSchema = z
  .object({
    appId: z.string().min(1),
    appSecret: z.string().min(1),
    domain: z.enum(['feishu', 'lark']).default('feishu'),
    oidc: z
      .object({
        enabled: z.boolean().default(true),
        scopes: z.array(z.string().min(1)).default(['contact:user.employee_id:readonly'])
      })
      .default({ enabled: true, scopes: ['contact:user.employee_id:readonly'] }),
    sync: z
      .object({
        users: z.boolean().default(true),
        departments: z.boolean().default(true),
        websocket: z.boolean().default(true),
        pageSize: z.number().int().min(1).max(50).default(50)
      })
      .default({ users: true, departments: true, websocket: true, pageSize: 50 }),
    /*
     * Kept only so older saved configs can still parse. The current Lark/Feishu
     * long-connection API does not need event verification token or encrypt key.
     */
    event: z
      .object({
        verificationToken: z.string().min(1).optional(),
        encryptKey: z.string().min(1).optional()
      })
      .default({})
  })
  .strict()

export type LarkChannelConfig = z.infer<typeof larkChannelConfigSchema>
export type LarkIdentityProviderConfig = z.infer<typeof larkIdentityProviderConfigSchema>

export class LarkAdapterConfigError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'LarkAdapterConfigError'
  }
}

export class LarkContactSyncUnavailableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'LarkContactSyncUnavailableError'
  }
}
