import { useIsMutating, useMutation, useQueryClient } from '@tanstack/react-query'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import {
  conversationNotFound,
  podKeys,
  postMessage,
  updateQueue,
  type ConversationDetail,
  type ConversationMessage,
  type ConversationPendingInput,
  type ConversationQueueRequest,
  type MessageSubmission
} from './api'
import { modelSelectionKey } from './model-controls'
import { acceptConversationResult, refreshConversationQueries } from './query-cache'
import { ChatModel, chatCommandPolicy, type FollowupMode } from './state/chat'
import type { ChatDrafts } from './state/chat-drafts'

type Model = InstanceType<typeof ChatModel>
export function editingText(detail: ConversationDetail, editing: NonNullable<Model['editing']['value']>) {
  return editing.kind === 'queue'
    ? detail.pendingInputs.find(input => input.messageID === editing.messageID)?.text
    : (detail.messages.find(message => message.id === editing.messageID)?.text ?? undefined)
}

/** Query mutations own requests; ChatModel keeps only the user's unfinished work. */
export function useChatCommands({
  model,
  drafts,
  conversationID,
  pageID,
  data,
  agentUID,
  agentsError,
  refresh
}: {
  model: Model
  drafts: ChatDrafts
  conversationID?: string
  pageID?: string
  data?: ConversationDetail
  agentUID: string
  agentsError: boolean
  refresh(): Promise<ConversationDetail | undefined>
}) {
  const client = useQueryClient()
  const queueKey = [...podKeys.detail(conversationID ?? ''), 'queue-command']
  useIsMutating({ mutationKey: modelSelectionKey(conversationID ?? '') })
  const send = useMutation({
    mutationFn: ({ submission, create }: { submission: MessageSubmission; owner: Model; create: boolean }) =>
      postMessage(submission, create),
    onSuccess: async (data, { submission, owner }) => {
      await acceptConversationResult(client, data)
      owner.accepted(submission)
      drafts.remember(owner, data.conversation.id, data.conversation.pageID ?? undefined)
      void refreshConversationQueries(client, data.conversation.id)
    },
    onError: (failure, { submission, owner, create }) => {
      owner.failed(failure, submission.messageID)
      if (!create && conversationNotFound(failure)) {
        owner.markGone()
        client.removeQueries({ queryKey: podKeys.detail(submission.conversationID), exact: true })
      } else void client.invalidateQueries({ queryKey: podKeys.agents })
      if (!create) void refreshConversationQueries(client, submission.conversationID)
    }
  })
  const queue = useMutation({
    mutationKey: queueKey,
    mutationFn: (command: ConversationQueueRequest) => updateQueue(conversationID!, command),
    onSuccess: async (data, command) => {
      await acceptConversationResult(client, data)
      if (
        (command.action === 'edit' || command.action === 'edit_last') &&
        command.messageID &&
        command.text !== undefined
      ) {
        model.editSaved(command.messageID, command.text)
      }
      if (command.action === 'stop' || command.action === 'resume') model.controlAccepted()
      void refreshConversationQueries(client, data.conversation.id)
    },
    onError: () => {
      if (conversationID) void refreshConversationQueries(client, conversationID)
    }
  })
  const recover = useMutation({
    mutationFn: async () => {
      const editing = model.editing.peek()
      if (!editing) return false
      const fresh = await refresh()
      const text = fresh && editingText(fresh, editing)
      return text !== undefined && model.rebaseEdit(editing.messageID, text, fresh!.queueVersion)
    },
    onSuccess: rebased => {
      if (rebased) queue.reset()
    }
  })
  const sending = (send.isPending && send.variables.owner === model) || model.pending.value?.state === 'sending'
  const working = !!data && (data.status.state !== 'idle' || !!model.live.value)
  const policy = () => {
    const editing = model.editing.value
    return chatCommandPolicy({
      sending: (send.isPending && send.variables.owner === model) || model.pending.value?.state === 'sending',
      queuePending: queue.isPending || client.isMutating({ mutationKey: queueKey }) > 0,
      modelSaving: !!conversationID && client.isMutating({ mutationKey: modelSelectionKey(conversationID) }) > 0,
      available: conversationID ? !!data?.conversation.agent.active : !!agentUID && !agentsError,
      working,
      hasQueued: !!data?.pendingInputs.length,
      hasSubmission: editing
        ? model.hasText.value || editing.hasAttachments
        : model.hasContent.value && model.attachments.canSend.value
    })
  }
  const changeQueue = (command: ConversationQueueRequest) => {
    if (!conversationID || !data || !policy().canQueue(command.action)) return
    queue.mutate({ ...command, expectedVersion: command.expectedVersion ?? data.queueVersion })
  }
  const submit = (mode?: FollowupMode) => {
    if (!policy().canSubmit) return
    const edit = model.editCommand()
    if (edit) changeQueue(edit)
    else {
      const submission = model.submit(conversationID, agentUID, () => crypto.randomUUID(), mode)
      // Release the new-chat slot without treating an unconfirmed create as a saved conversation.
      if (!conversationID && !pageID) drafts.remember(model, submission.conversationID)
      send.mutate({
        submission: { ...submission, ...(pageID ? { pageID } : {}) },
        owner: model,
        create: !conversationID
      })
    }
  }
  const editLast = (message: ConversationMessage) => {
    if (data && policy().canRetryLast) {
      model.beginEdit(message.id, message.text, data.queueVersion, 'last', message.attachments.length > 0)
    }
  }
  const editQueued = (input: ConversationPendingInput) => {
    if (data && policy().canQueue('edit')) {
      model.beginEdit(input.messageID, input.text, data.queueVersion, 'queue', input.attachments.length > 0)
    }
  }
  const useSaved = () => {
    const editing = model.editing.value
    const saved = data && editing && editingText(data, editing)
    if (data && editing && saved !== undefined && model.rebaseEdit(editing.messageID, saved, data.queueVersion, true)) {
      queue.reset()
    }
  }
  return {
    ...policy(),
    sending,
    working,
    submit,
    changeQueue,
    editQueued,
    followupRelevant: working || !!data?.queuePaused || !!data?.pendingInputs.length,
    stop: () => changeQueue({ action: 'stop', commandID: model.stopID(() => crypto.randomUUID()) }),
    messageActions: policy().canRetryLast
      ? {
          edit: editLast,
          regenerate: (message: ConversationMessage) =>
            changeQueue({ action: 'regenerate', messageID: message.id, commandID: crypto.randomUUID() })
        }
      : undefined,
    queueError: queue.error,
    editConflict:
      queue.error instanceof InternalAPIError &&
      requestErrorCode(queue.error.payload) === 'queue_changed' &&
      !!model.editing.value,
    recovery: { loading: recover.isPending, error: recover.error, refresh: () => recover.mutate(), useSaved }
  }
}

export type ChatCommands = ReturnType<typeof useChatCommands>
