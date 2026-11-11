import { equal } from '@agentbull/active-support'
import { signal } from '@preact/signals-react'
import { ChatModel } from './chat'

type Model = InstanceType<typeof ChatModel>

export function unsavedInlineEditDraft(model: Model, reactive = false): string {
  const editing = reactive ? model.editing.value : model.editing.peek()
  if (editing?.kind !== 'last') return ''
  const text = reactive ? model.editDraft.value : model.editDraft.peek()
  const links = reactive ? model.editLinks.value : model.editLinks.peek()
  return text.trim() !== '' && (text !== editing.originalText || !equal(links, editing.originalLinks)) ? text : ''
}

export type PendingPageQuote = {
  /** Set when targeting a Page's side-sheet chat; omitted when navigating to a standalone `/conversations/:id` room. */
  pageID?: string
  /** Page ID attached to `model.quote(...)` when `quote` is present (defaults to `pageID`). */
  sourcePageID?: string
  /** `'latest'` while `PageChat` resolves the target conversation, `'new'` for a fresh draft, or a `conversationID`. */
  target: string
  quote?: string
  prompt?: string
}

/** One Pod owns its unfinished conversations for the lifetime of the document. */
export class ChatDrafts {
  private readonly models = new Map<string, Model>()
  private readonly pageModels = new Map<string, Set<Model>>()
  readonly newChatVersion = signal(0)

  startNew(): void {
    const current = this.models.get('new:chat')
    if (current && hasUnsentChatWork(current)) this.remember(current, crypto.randomUUID())
    else current?.attachments.dispose()
    this.models.delete('new:chat')
    this.newChatVersion.value++
  }
  /**
   * A Page selection or Applet prompt waiting for its resolved target chat composer.
   */
  readonly pageQuote = signal<PendingPageQuote | null>(null)

  resolvePageQuoteTarget(pageID: string, target: string | null): void {
    const current = this.pageQuote.peek()
    if (!current || current.pageID !== pageID || current.target !== 'latest') return
    if (!target) {
      this.pageQuote.value = null
      return
    }
    if (target !== 'latest') {
      this.pageQuote.value = { ...current, target }
    }
  }

  consumePageQuote(context: { pageID?: string; conversationID?: string }): PendingPageQuote | null {
    const current = this.pageQuote.peek()
    if (!current || current.target === 'latest') return null
    const matchesPageChat = Boolean(
      context.pageID && current.pageID === context.pageID && current.target === (context.conversationID ?? 'new')
    )
    const matchesStandaloneChat = Boolean(
      !context.pageID && !current.pageID && context.conversationID && current.target === context.conversationID
    )
    if (!matchesPageChat && !matchesStandaloneChat) return null
    this.pageQuote.value = null
    return current
  }

  get(conversationID?: string, pageID?: string, colleagueUID?: string): Model {
    const key = conversationID
      ? `conversation:${conversationID}`
      : `new:${colleagueUID ? `dm:${colleagueUID}` : (pageID ?? 'chat')}`
    const existing = this.models.get(key)
    if (existing) {
      this.recordPage(pageID, existing)
      return existing
    }
    if (conversationID) {
      for (const model of this.models.values()) {
        if (model.pending.peek()?.conversationID === conversationID) {
          this.remember(model, conversationID)
          this.recordPage(pageID, model)
          return model
        }
      }
    }
    const model = new ChatModel()
    model.conversationID.value = conversationID
    this.models.set(key, model)
    this.recordPage(pageID, model)
    return model
  }

  remember(model: Model, conversationID: string, pageID?: string): void {
    for (const [key, value] of this.models) {
      if (value === model) this.models.delete(key)
    }
    this.models.set(`conversation:${conversationID}`, model)
    this.recordPage(pageID, model)
  }

  unconfirmedStandalone() {
    return [...this.models.entries()].flatMap(([key, model]) => {
      const pending = model.pending.value
      if (
        model.conversationID.value ||
        (!pending && (!key.startsWith('conversation:') || !hasUnsentChatWork(model))) ||
        [...this.pageModels.values()].some(models => models.has(model))
      ) {
        return []
      }
      return [{ id: pending?.conversationID ?? key.slice('conversation:'.length), model }]
    })
  }

  hasUnsentWork(): boolean {
    return [...this.models.values()].some(hasUnsentChatWork)
  }

  unfinishedPageConversation(pageID: string): string | undefined {
    const model = [...(this.pageModels.get(pageID) ?? [])].reverse().find(hasUnsentChatWork)
    return model ? (model.conversationID.peek() ?? 'new') : undefined
  }

  localPageDrafts(pageID: string): { key: string; text: string }[] {
    return [...(this.pageModels.get(pageID) ?? [])].flatMap((model, index) => {
      const texts = new Set([
        model.draft.value,
        model.pending.value?.text ?? '',
        model.editing.value?.previousDraft ?? '',
        unsavedInlineEditDraft(model, true)
      ])
      return [...texts].filter(text => text.trim() !== '').map((text, part) => ({ key: `${index}:${part}`, text }))
    })
  }

  localPageAttachments(pageID: string) {
    return [...(this.pageModels.get(pageID) ?? [])]
      .filter(model => model.attachments.hasFiles.value)
      .map(model => model.attachments)
  }

  dispose(): void {
    for (const model of this.models.values()) model.attachments.dispose()
  }

  private recordPage(pageID: string | undefined, model: Model): void {
    if (!pageID) return
    let models = this.pageModels.get(pageID)
    if (!models) {
      models = new Set()
      this.pageModels.set(pageID, models)
    }
    models.delete(model)
    models.add(model)
  }
}

export function hasUnsentChatWork(model: Model): boolean {
  return (
    model.draft.peek().trim() !== '' ||
    model.attachments.hasFiles.peek() ||
    !!model.pending.peek() ||
    !!model.editing.peek()?.previousDraft.trim() ||
    unsavedInlineEditDraft(model) !== ''
  )
}
