import type {
  ExternalGatewayAdapter,
  ExternalGatewayAdapterCapabilities,
  ExternalGatewayWebhookOptions
} from '@/external-gateway/core'

const HEADLESS_CAPABILITIES = {
  inbound: [],
  outbound: []
} as const satisfies ExternalGatewayAdapterCapabilities

export function createHeadlessAdapter(name: string): ExternalGatewayAdapter {
  return {
    name,
    capabilities: HEADLESS_CAPABILITIES,
    async initialize() {},
    async disconnect() {},
    async handleWebhook(_request: Request, _options?: ExternalGatewayWebhookOptions): Promise<Response> {
      return new Response('Headless scheduler adapter does not accept webhooks', { status: 405 })
    },
    parseMessage() {
      throw new Error('Headless scheduler adapter cannot parse provider messages')
    },
    channelIdFromThreadId(threadId: string): string {
      return threadId
    },
    decodeThreadId(threadId: string): string {
      return threadId
    },
    encodeThreadId(threadId: string): string {
      return threadId
    },
    isDM() {
      return false
    },
    async fetchMessage() {
      return null
    },
    async fetchThread(threadId: string) {
      return {
        id: threadId,
        channelId: threadId,
        isDM: false,
        metadata: {}
      }
    }
  } as unknown as ExternalGatewayAdapter
}
