import type { BullXStreamingCardHandle, BullXStreamingCardStatus } from '@agentbull/bullx-sdk/plugins'
import { asRecord, optionalString } from './lark-helpers'
import type { SharedLarkConnection } from './connection'

const STREAMING_ELEMENT_ID = 'content'
const STREAM_THINKING = '思考中…'
const STREAM_EMPTY = '（无内容）'

export interface LarkStreamingCardOptions {
  chatId: string
  rootId?: string
  idempotencyKey?: string
  initialText?: string
  intervalMs: number
  bufferThreshold: number
  logger?: { warn?: (...args: unknown[]) => void }
}

/**
 * Create + send a Lark CardKit streaming card, returning a handle the host feeds
 * with the answer text so far. Mirrors Elixir `Feishu.StreamingCard`:
 * cardkit.card.create (card_json) -> send interactive message referencing card_id ->
 * cardElement.update replaces the placeholder element on first write, then
 * cardElement.content patches it (sequence-ordered, throttled) -> card.settings
 * closes streaming on finish. All calls use the SDK's typed CardKit resource.
 *
 * Errors are isolated: streaming is decorative, so a failed CardKit call degrades
 * the session (subsequent writes short-circuit) instead of throwing into the run.
 */
export async function createLarkStreamingCardSession(
  connection: SharedLarkConnection,
  options: LarkStreamingCardOptions
): Promise<BullXStreamingCardHandle> {
  const session = new LarkStreamingCardSession(connection, options)
  await session.start()
  return session
}

class LarkStreamingCardSession implements BullXStreamingCardHandle {
  cardId = ''
  messageId = ''

  private sequence = 0
  private lastUpdateMs = 0
  private lastWrittenLen = 0
  private lastWrittenText = ''
  private contentReady = false
  private degraded = false
  private latestText = ''
  private tail: Promise<void> = Promise.resolve()

  constructor(
    private readonly connection: SharedLarkConnection,
    private readonly options: LarkStreamingCardOptions
  ) {}

  async start(): Promise<void> {
    try {
      const created = await this.connection.rawClient.cardkit.v1.card.create({
        data: {
          type: 'card_json',
          data: JSON.stringify(streamingCardDefinition(this.options.initialText ?? STREAM_THINKING))
        }
      })
      this.cardId = optionalString(created?.data?.card_id) ?? ''
      if (!this.cardId) {
        this.degraded = true
        return
      }
      const content = JSON.stringify({ type: 'card', data: { card_id: this.cardId } })
      const rootId = optionalString(this.options.rootId)
      const sent = rootId
        ? await this.connection.rawClient.im.v1.message.reply({
            path: { message_id: rootId },
            data: { msg_type: 'interactive', content, reply_in_thread: true, uuid: this.options.idempotencyKey }
          })
        : await this.connection.rawClient.im.v1.message.create({
            params: { receive_id_type: 'chat_id' },
            data: {
              receive_id: this.options.chatId,
              msg_type: 'interactive',
              content,
              uuid: this.options.idempotencyKey
            }
          })
      this.messageId = optionalString(asRecord(asRecord(sent)?.data)?.message_id) ?? ''
      if (!this.messageId) this.degraded = true
    } catch (error) {
      this.degraded = true
      this.options.logger?.warn?.('lark streaming card start failed', error)
    }
  }

  async update(fullText: string): Promise<void> {
    this.latestText = fullText
    this.tail = this.tail.then(() => this.flush(false))
    return this.tail
  }

  async finish(finalText: string, status: BullXStreamingCardStatus): Promise<void> {
    const display = finalText.trim() ? finalText : fallbackForStatus(status)
    this.latestText = display || STREAM_EMPTY
    this.tail = this.tail.then(() => this.flush(true))
    await this.tail
    if (this.degraded || !this.cardId) return
    try {
      this.sequence += 1
      await this.connection.rawClient.cardkit.v1.card.settings({
        path: { card_id: this.cardId },
        data: {
          settings: JSON.stringify({
            config: { streaming_mode: false, summary: { content: truncateSummary(this.latestText) } }
          }),
          sequence: this.sequence,
          uuid: crypto.randomUUID()
        }
      })
    } catch (error) {
      // Best-effort close: leaving streaming_mode on is a visual blemish, not a
      // correctness failure (the host still records the card as delivered).
      this.options.logger?.warn?.('lark streaming card finish failed', error)
    }
  }

  private async flush(force: boolean): Promise<void> {
    if (this.degraded || !this.cardId) return
    const text = this.latestText
    if (text.length === 0) return
    if (!force && !this.isDue(text)) return
    if (text === this.lastWrittenText) return
    try {
      this.sequence += 1
      if (!this.contentReady) {
        // First write replaces the placeholder element with a markdown element.
        await this.connection.rawClient.cardkit.v1.cardElement.update({
          path: { card_id: this.cardId, element_id: STREAMING_ELEMENT_ID },
          data: {
            element: JSON.stringify({ tag: 'markdown', content: text, element_id: STREAMING_ELEMENT_ID }),
            sequence: this.sequence,
            uuid: crypto.randomUUID()
          }
        })
        this.contentReady = true
      } else {
        await this.connection.rawClient.cardkit.v1.cardElement.content({
          path: { card_id: this.cardId, element_id: STREAMING_ELEMENT_ID },
          data: { content: text, sequence: this.sequence, uuid: crypto.randomUUID() }
        })
      }
      this.lastUpdateMs = Date.now()
      this.lastWrittenLen = text.length
      this.lastWrittenText = text
    } catch (error) {
      this.degraded = true
      this.options.logger?.warn?.('lark streaming card update failed', error)
    }
  }

  private isDue(text: string): boolean {
    if (this.lastUpdateMs === 0) return true
    if (Date.now() - this.lastUpdateMs >= this.options.intervalMs) return true
    return text.length - this.lastWrittenLen >= this.options.bufferThreshold
  }
}

function fallbackForStatus(status: BullXStreamingCardStatus): string {
  if (status === 'cancelled') return '已停止'
  if (status === 'failed') return '出错了'
  return ''
}

function truncateSummary(text: string): string {
  const normalized = text.replace(/\s+/g, ' ').trim()
  return normalized.length <= 80 ? normalized : `${normalized.slice(0, 77)}...`
}

function streamingCardDefinition(initialText: string): Record<string, unknown> {
  return {
    schema: '2.0',
    config: {
      update_multi: true,
      streaming_mode: true,
      summary: { content: STREAM_THINKING },
      streaming_config: {
        print_frequency_ms: { default: 70, android: 70, ios: 70, pc: 70 },
        print_step: { default: 1, android: 1, ios: 1, pc: 1 },
        print_strategy: 'fast'
      }
    },
    body: {
      direction: 'vertical',
      horizontal_spacing: '8px',
      vertical_spacing: '8px',
      horizontal_align: 'left',
      vertical_align: 'top',
      padding: '12px 12px 12px 12px',
      elements: [
        {
          tag: 'div',
          text: {
            tag: 'plain_text',
            content: initialText,
            text_size: 'notation',
            text_align: 'left',
            text_color: 'grey'
          },
          icon: { tag: 'standard_icon', token: 'ai-common_colorful', color: 'grey' },
          margin: '0px 0px 0px 0px',
          element_id: STREAMING_ELEMENT_ID
        }
      ]
    }
  }
}
