import { createLarkAdapter } from '@larksuite/vercel-chat-adapter'
import type { BullXChatGatewayAdapterFactoryContext, BullXPlugin } from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'

const larkChannelConfigSchema = z
  .object({
    appId: z.string().min(1),
    appSecret: z.string().min(1),
    userName: z.string().min(1).optional()
  })
  .strict()

export type LarkChannelConfig = z.infer<typeof larkChannelConfigSchema>

export class LarkAdapterConfigError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'LarkAdapterConfigError'
  }
}

export function createBullXLarkAdapter(context: BullXChatGatewayAdapterFactoryContext) {
  const parsed = larkChannelConfigSchema.safeParse(context.config)
  if (!parsed.success) {
    throw new LarkAdapterConfigError(`Invalid Lark adapter config for channel ${context.channel.name}`, {
      cause: parsed.error
    })
  }

  return createLarkAdapter({
    appId: parsed.data.appId,
    appSecret: parsed.data.appSecret,
    userName: parsed.data.userName
  })
}

export const larkAdapterPlugin = {
  metadata: {
    id: 'lark-adapter',
    apiVersion: 1,
    displayName: 'Lark / Feishu Chat Adapter',
    description: 'First-party Chat SDK adapter plugin for Lark and Feishu long-connection bots.'
  },
  chatGatewayAdapters: [
    {
      id: 'lark',
      create: createBullXLarkAdapter
    }
  ]
} satisfies BullXPlugin

export default larkAdapterPlugin
