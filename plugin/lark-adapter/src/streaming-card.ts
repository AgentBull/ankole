import type {
  BullXStreamingCardFinishResult,
  BullXStreamingCardHandle,
  BullXStreamingCardStatus
} from '@agentbull/bullx-sdk/plugins'
import { asRecord, assertLarkSuccess, optionalString } from './lark-helpers'
import type { SharedLarkConnection } from './connection'

const STREAMING_ELEMENT_ID = 'content'
const STREAM_THINKING = '思考中…'
const STREAM_EMPTY = '（无内容）'
const DEFAULT_CARD_ID_RETRY_DELAYS_MS = [250, 750, 1500, 3000, 5000]

export interface LarkStreamingCardOptions {
  chatId: string
  rootId?: string
  idempotencyKey?: string
  initialText?: string
  intervalMs: number
  bufferThreshold: number
  cardIdRetryDelaysMs?: number[]
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
 * Errors are isolated: streaming is decorative, so provider write failures are
 * kept inside the session. Preview writes can fail and be retried by a later
 * suffix/finalize write; `finish` reports whether the final text was confirmed.
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
  private flushTimer: ReturnType<typeof setTimeout> | null = null
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
      assertLarkSuccess(created, 'cardkit card create')
      this.cardId = optionalString(created?.data?.card_id) ?? ''
      if (!this.cardId) {
        this.degraded = true
        return
      }
      const content = JSON.stringify({ type: 'card', data: { card_id: this.cardId } })
      const rootId = optionalString(this.options.rootId)
      const sent = await this.sendCardMessageWithCardIdRetry(() =>
        rootId
          ? this.connection.rawClient.im.v1.message.reply({
              path: { message_id: rootId },
              data: { msg_type: 'interactive', content, reply_in_thread: false, uuid: this.options.idempotencyKey }
            })
          : this.connection.rawClient.im.v1.message.create({
              params: { receive_id_type: 'chat_id' },
              data: {
                receive_id: this.options.chatId,
                msg_type: 'interactive',
                content,
                uuid: this.options.idempotencyKey
              }
            })
      )
      this.messageId = optionalString(asRecord(asRecord(sent)?.data)?.message_id) ?? ''
      if (!this.messageId) this.degraded = true
    } catch (error) {
      this.degraded = true
      this.options.logger?.warn?.('lark streaming card start failed', error)
    }
  }

  async update(fullText: string): Promise<void> {
    this.latestText = mergeStreamingText(this.latestText, fullText)
    this.tail = this.tail.then(() => this.flush(false).then(() => undefined))
    return this.tail
  }

  async finish(finalText: string, status: BullXStreamingCardStatus): Promise<BullXStreamingCardFinishResult> {
    const display = finalText.trim() ? finalText : fallbackForStatus(status)
    this.latestText = display || STREAM_EMPTY
    this.clearFlushTimer()
    this.tail = this.tail.then(() => this.flush(true).then(() => undefined))
    await this.tail
    const delivered = Boolean(this.cardId && this.messageId)
    const finalTextConfirmed = delivered && this.lastWrittenText === this.latestText
    if (this.degraded || !this.cardId) {
      return {
        delivered,
        finalTextConfirmed,
        fallbackReason: this.degraded ? 'streaming_card_degraded' : 'missing_card_id'
      }
    }
    try {
      this.sequence += 1
      const response = await this.connection.rawClient.cardkit.v1.card.settings({
        path: { card_id: this.cardId },
        data: {
          settings: JSON.stringify({
            config: { streaming_mode: false, summary: { content: truncateSummary(this.latestText) } }
          }),
          sequence: this.sequence,
          uuid: crypto.randomUUID()
        }
      })
      assertLarkSuccess(response, 'cardkit card settings')
    } catch (error) {
      // Best-effort close: leaving streaming_mode on is a visual blemish, not a
      // correctness failure (the host still records the card as delivered).
      this.options.logger?.warn?.('lark streaming card finish failed', error)
    }
    return {
      delivered,
      finalTextConfirmed,
      fallbackReason: finalTextConfirmed ? undefined : 'final_text_unconfirmed'
    }
  }

  private async flush(force: boolean): Promise<boolean> {
    if (this.degraded || !this.cardId) return false
    const text = this.latestText
    if (text.length === 0) return false
    if (!force && !this.isDue(text)) {
      this.schedulePendingFlush()
      return false
    }
    if (text === this.lastWrittenText) return true
    this.clearFlushTimer()
    try {
      this.sequence += 1
      if (!this.contentReady) {
        // First write replaces the placeholder element with a markdown element.
        await this.replaceElement(text, 'cardkit card element update')
        this.contentReady = true
      } else if (text.startsWith(this.lastWrittenText)) {
        const suffix = text.slice(this.lastWrittenText.length)
        if (suffix.length === 0) return true
        const response = await this.connection.rawClient.cardkit.v1.cardElement.content({
          path: { card_id: this.cardId, element_id: STREAMING_ELEMENT_ID },
          data: { content: larkCardMarkdown(suffix), sequence: this.sequence, uuid: crypto.randomUUID() }
        })
        assertLarkSuccess(response, 'cardkit card element content')
      } else {
        await this.replaceElement(text, 'cardkit card element replace')
        this.contentReady = true
      }
      this.lastUpdateMs = Date.now()
      this.lastWrittenLen = text.length
      this.lastWrittenText = text
      return true
    } catch (error) {
      this.options.logger?.warn?.('lark streaming card update failed', error)
      return false
    }
  }

  private async replaceElement(text: string, operation: string): Promise<void> {
    const response = await this.connection.rawClient.cardkit.v1.cardElement.update({
      path: { card_id: this.cardId, element_id: STREAMING_ELEMENT_ID },
      data: {
        element: JSON.stringify({ tag: 'markdown', content: larkCardMarkdown(text), element_id: STREAMING_ELEMENT_ID }),
        sequence: this.sequence,
        uuid: crypto.randomUUID()
      }
    })
    assertLarkSuccess(response, operation)
  }

  private isDue(text: string): boolean {
    if (this.lastUpdateMs === 0) return true
    if (hasNaturalStreamingBoundary(text) && text !== this.lastWrittenText) return true
    if (Date.now() - this.lastUpdateMs >= this.options.intervalMs) return true
    return text.length - this.lastWrittenLen >= this.options.bufferThreshold
  }

  private clearFlushTimer(): void {
    if (!this.flushTimer) return
    clearTimeout(this.flushTimer)
    this.flushTimer = null
  }

  private schedulePendingFlush(): void {
    if (this.flushTimer || this.degraded || !this.cardId || !this.latestText) return
    const delayMs = Math.max(0, this.options.intervalMs - (Date.now() - this.lastUpdateMs))
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null
      this.tail = this.tail.then(() => this.flush(false).then(() => undefined))
      this.tail.catch(error => {
        this.options.logger?.warn?.('lark streaming card pending flush failed', error)
      })
    }, delayMs)
  }

  private async sendCardMessageWithCardIdRetry(send: () => Promise<unknown>): Promise<unknown> {
    const retryDelaysMs = this.options.cardIdRetryDelaysMs ?? DEFAULT_CARD_ID_RETRY_DELAYS_MS
    for (let attempt = 0; ; attempt++) {
      try {
        return await send()
      } catch (error) {
        const delayMs = retryDelaysMs[attempt]
        if (delayMs === undefined || !isInvalidCardIdError(error)) throw error
        await Bun.sleep(delayMs)
      }
    }
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

function hasNaturalStreamingBoundary(text: string): boolean {
  return /[\n。！？!?；;：:]$/.test(text)
}

export function mergeStreamingText(previousText: string | undefined, nextText: string | undefined): string {
  const previous = typeof previousText === 'string' ? previousText : ''
  const next = typeof nextText === 'string' ? nextText : ''
  if (!next) return previous
  if (!previous || next === previous) return next
  if (next.startsWith(previous)) return next
  if (previous.startsWith(next)) return previous
  if (next.includes(previous)) return next
  if (previous.includes(next)) return previous

  const maxOverlap = Math.min(previous.length, next.length)
  for (let overlap = maxOverlap; overlap > 0; overlap--) {
    if (previous.slice(-overlap) === next.slice(0, overlap)) return `${previous}${next.slice(overlap)}`
  }
  return `${previous}${next}`
}

function isInvalidCardIdError(error: unknown): boolean {
  const response = asRecord(asRecord(error)?.response)
  const data = asRecord(response?.data)
  const code = data?.code
  const msg = optionalString(data?.msg)?.toLowerCase()
  return code === 230099 && Boolean(msg?.includes('cardid is invalid'))
}

function larkCardMarkdown(text: string): string {
  return text.replace(/```([^\n`]*)\n([\s\S]*?)```/g, (_match, language: string, body: string) => {
    const label = language.trim()
    const lines = body.replace(/\n$/, '').split(/\r?\n/)
    const rendered = lines.map(line => `\`${escapeInlineCode(line || ' ')}\``)
    return [label ? `\`${escapeInlineCode(label)}\`` : undefined, ...rendered].filter(Boolean).join('\n')
  })
}

function escapeInlineCode(text: string): string {
  return text.replace(/`/g, '\\`')
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
