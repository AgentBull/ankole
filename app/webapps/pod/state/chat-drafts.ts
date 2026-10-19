import { ChatModel } from './chat'

type Model = InstanceType<typeof ChatModel>

/** One Pod owns its unfinished conversations for the lifetime of the document. */
export class ChatDrafts {
  private readonly models = new Map<string, Model>()
  private readonly pageModels = new Map<string, Set<Model>>()

  get(conversationID?: string, pageID?: string): Model {
    const key = conversationID ? `conversation:${conversationID}` : `new:${pageID ?? 'chat'}`
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
    return [...this.models.values()].flatMap(model => {
      const pending = model.pending.value
      if (model.conversationID.value || !pending || [...this.pageModels.values()].some(models => models.has(model)))
        return []
      return [{ id: pending.conversationID, model }]
    })
  }

  hasUnsentWork(): boolean {
    return [...this.models.values()].some(unfinished)
  }

  unfinishedPageConversation(pageID: string): string | undefined {
    const model = [...(this.pageModels.get(pageID) ?? [])].reverse().find(unfinished)
    return model ? (model.conversationID.peek() ?? 'new') : undefined
  }

  localPageDrafts(pageID: string): { key: string; text: string }[] {
    return [...(this.pageModels.get(pageID) ?? [])].flatMap((model, index) => {
      const texts = new Set([
        model.draft.value,
        model.pending.value?.text ?? '',
        model.editing.value?.previousDraft ?? ''
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

function unfinished(model: Model): boolean {
  return (
    model.draft.peek().trim() !== '' ||
    model.attachments.hasFiles.peek() ||
    !!model.pending.peek() ||
    !!model.editing.peek()?.previousDraft.trim()
  )
}
