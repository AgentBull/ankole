import { useIsMutating, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from '@ankole/uikit'
import { t } from 'i18next'
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
import { restoreConversationFiles } from './native-transfers'
import { modelSelectionKey } from './model-controls'
import { acceptConversationResult, refreshConversationQueries } from './query-cache'
import { ChatModel, chatCommandPolicy, draftLinks, draftMentions, type ChatEditSnapshot } from './state/chat'
import type { ChatDrafts } from './state/chat-drafts'

type Model = InstanceType<typeof ChatModel>
export function editingSnapshot(
  detail: ConversationDetail,
  editing: NonNullable<Model['editing']['value']>
): ChatEditSnapshot | undefined {
  const message =
    editing.kind === 'queue'
      ? detail.pendingQueues
          .find(queue => queue.agentUID === editing.agentUID)
          ?.inputs.find(input => input.messageID === editing.messageID)
      : detail.messages.find(message => message.id === editing.messageID)
  return message && { text: message.text, links: draftLinks(message.links), mentions: draftMentions(message.mentions) }
}

/** Query mutations own requests; ChatModel keeps only the user's unfinished work. */
export function useChatCommands({
  model,
  drafts,
  conversationID,
  pageID,
  accessScope,
  data,
  agentUID,
  agentsError,
  callableAgentUIDs,
  refresh
}: {
  model: Model
  drafts: ChatDrafts
  conversationID?: string
  pageID?: string
  accessScope?: 'participants' | 'anchor_page'
  data?: ConversationDetail
  agentUID: string
  agentsError: boolean
  callableAgentUIDs: string[]
  refresh(): Promise<ConversationDetail | undefined>
}) {
  const client = useQueryClient()
  const queueKey = [...podKeys.detail(conversationID ?? ''), 'queue-command']
  const queuePending = useIsMutating({ mutationKey: queueKey }) > 0
  useIsMutating({ mutationKey: modelSelectionKey(conversationID ?? '') })
  const send = useMutation({
    mutationFn: ({ submission, create }: { submission: MessageSubmission; owner: Model; create: boolean }) =>
      postMessage(submission, create),
    onSuccess: async (data, { submission, owner }) => {
      await acceptConversationResult(client, data)
      const outsiders = (submission.mentions ?? []).filter(
        mention =>
          mention.type === 'human' && !data.conversation.participants.some(person => person.uid === mention.uid)
      )
      owner.neededInvites.value = outsiders.map(person => ({
        uid: person.uid,
        displayName: person.displayName || person.uid
      }))
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
      if ((command.action === 'edit' || command.action === 'edit_last') && command.messageID && command.text != null) {
        model.editSaved(command.messageID, command.text, command.links ? draftLinks(command.links) : [])
      }
      if (command.action === 'stop' || command.action === 'resume') model.controlAccepted()
      void refreshConversationQueries(client, data.conversation.id)
    },
    onError: () => {
      if (conversationID) void refreshConversationQueries(client, conversationID)
    }
  })
  const takeBack = useMutation({
    mutationKey: queueKey,
    mutationFn: async ({ input, agentUID }: { input: ConversationPendingInput; agentUID: string }) => {
      const files = await restoreConversationFiles(conversationID!, input.messageID, input.attachments)
      const slot = data!.pendingQueues.find(queue => queue.agentUID === agentUID)!
      const result = await updateQueue(conversationID!, {
        action: 'retract',
        agentUID,
        messageID: input.messageID,
        expectedVersion: slot.queueVersion
      })
      return { result, files }
    },
    onSuccess: async ({ result, files }, { input, agentUID }) => {
      await acceptConversationResult(client, result)
      model.restoreQueuedInput(input, agentUID)
      model.attachments.add(files)
      void refreshConversationQueries(client, result.conversation.id)
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
      if (!fresh) return false
      const saved = editingSnapshot(fresh, editing)
      if (!saved) return false
      const slot = fresh.pendingQueues.find(queue => queue.agentUID === editing.agentUID)
      return !!slot && model.rebaseEdit(editing.messageID, saved, slot.queueVersion)
    },
    onSuccess: rebased => {
      if (rebased) queue.reset()
    }
  })
  const sending = (send.isPending && send.variables.owner === model) || model.pending.value?.state === 'sending'
  const working =
    !!data &&
    (data.pendingQueues.some(queue => queue.workStatus.state !== 'idle') ||
      data.conversation.agents.some(agent => model.liveStreams.value[agent.uid]))
  const policy = (targetUID = agentUID) => {
    const editing = model.editing.value
    const slot = data?.pendingQueues.find(queue => queue.agentUID === targetUID)
    return chatCommandPolicy({
      sending,
      queuePending,
      modelSaving:
        !!conversationID && client.isMutating({ mutationKey: [...modelSelectionKey(conversationID), targetUID] }) > 0,
      available: conversationID
        ? !!data &&
          (data.conversation.roomMode === 'group' ||
            data.conversation.accessScope === 'anchor_page' ||
            data.conversation.agents.some(agent => agent.active && callableAgentUIDs.includes(agent.uid)))
        : !!agentUID && !agentsError,
      working: !!slot && (slot.workStatus.state !== 'idle' || !!model.liveStreams.value[targetUID]),
      hasQueued: !!slot?.inputs.length,
      hasSubmission: editing
        ? model.hasText.value || editing.hasAttachments
        : model.hasContent.value && model.attachments.canSend.value
    })
  }
  const latestInput = data?.latestInput
  const editTargetUID = latestInput?.agentUIDs.length === 1 ? latestInput.agentUIDs[0] : undefined
  const editTargetQueue = data?.pendingQueues.find(queue => queue.agentUID === editTargetUID)
  const editDisabledReason = latestInput
    ? latestInput.agentUIDs.length === 0
      ? t('pod.chat_timeline.no_agent_edit')
      : latestInput.agentUIDs.length > 1
        ? t('pod.chat_timeline.multi_agent_edit')
        : undefined
    : undefined
  const canEditLast =
    !!editTargetUID &&
    callableAgentUIDs.includes(editTargetUID) &&
    !!data?.conversation.agents.some(agent => agent.uid === editTargetUID && agent.active) &&
    !!editTargetQueue &&
    policy(editTargetUID).canRetryLast
  const changeQueue = (command: ConversationQueueRequest) => {
    const slot = data?.pendingQueues.find(queue => queue.agentUID === command.agentUID)
    if (!conversationID || !slot || !policy(slot.agentUID).canQueue(command.action)) return
    queue.mutate({
      ...command,
      expectedVersion: command.expectedVersion ?? slot.queueVersion
    })
  }
  const submit = () => {
    if (!policy().canSubmit) return
    const edit = model.editCommand()
    if (edit) changeQueue(edit)
    else {
      const submission = model.submit(conversationID, agentUID, () => crypto.randomUUID())
      // Release the new-chat slot without treating an unconfirmed create as a saved conversation.
      if (!conversationID && !pageID) drafts.remember(model, submission.conversationID)
      send.mutate({
        submission: { ...submission, ...(pageID ? { pageID, accessScope } : {}) },
        owner: model,
        create: !conversationID
      })
    }
  }
  const editLast = (message: ConversationMessage) => {
    if (
      data &&
      message.id === latestInput?.messageID &&
      latestInput.authorUID === data.conversation.viewer.uid &&
      !model.editing.value
    ) {
      if (editDisabledReason) {
        toast.info(editDisabledReason)
        return
      }
      if (!canEditLast || !editTargetQueue) return
      model.beginEdit({
        messageID: message.id,
        text: message.text,
        queueVersion: editTargetQueue.queueVersion,
        kind: 'last',
        hasAttachments: message.attachments.length > 0,
        agentUID: editTargetQueue.agentUID,
        links: draftLinks(message.links),
        mentions: draftMentions(message.mentions)
      })
    }
  }
  const editQueued = (input: ConversationPendingInput, agentUID: string) => {
    const slot = data?.pendingQueues.find(queue => queue.agentUID === agentUID)
    if (
      slot &&
      callableAgentUIDs.includes(agentUID) &&
      data?.conversation.agents.some(agent => agent.uid === agentUID && agent.active) &&
      policy(agentUID).canQueue('edit')
    ) {
      model.beginEdit({
        messageID: input.messageID,
        text: input.text,
        queueVersion: slot.queueVersion,
        kind: 'queue',
        hasAttachments: input.attachments.length > 0,
        agentUID,
        links: draftLinks(input.links),
        mentions: draftMentions(input.mentions)
      })
    }
  }
  const useSaved = () => {
    const editing = model.editing.value
    const saved = data && editing && editingSnapshot(data, editing)
    const slot = data?.pendingQueues.find(queue => queue.agentUID === editing?.agentUID)
    if (editing && saved && slot && model.rebaseEdit(editing.messageID, saved, slot.queueVersion, true)) {
      queue.reset()
    }
  }
  const stoppable =
    data?.pendingQueues
      .filter(
        slot =>
          callableAgentUIDs.includes(slot.agentUID) &&
          slot.workStatus.state !== 'idle' &&
          (!model.targetAgentUID.value || model.targetAgentUID.value === slot.agentUID)
      )
      .map(slot => slot.agentUID) ?? []
  return {
    ...policy(),
    sending,
    working,
    submit,
    changeQueue,
    editQueued,
    recallLast: () => {
      if (!data || latestInput?.authorUID !== data.conversation.viewer.uid) return
      const last = data.messages.find(message => message.id === latestInput.messageID)
      if (!last) return
      const queued = data.pendingQueues
        .flatMap(queue => queue.inputs.map(input => ({ input, agentUID: queue.agentUID })))
        .findLast(item => item.input.messageID === last.id)
      if (queued) editQueued(queued.input, queued.agentUID)
      else editLast(last)
    },
    takeBackQueued: (input: ConversationPendingInput, agentUID: string) => {
      if (!model.editing.value) takeBack.mutate({ input, agentUID })
    },
    canStop: stoppable.length > 0,
    stop: () => {
      if (!data || !policy().canQueue('stop')) return
      const commandID = model.stopID(() => crypto.randomUUID())
      void (async () => {
        for (const agentUID of stoppable) {
          await queue.mutateAsync({ action: 'stop', agentUID, commandID })
        }
      })().catch(() => {})
    },
    messageActions: !policy().disabled
      ? {
          edit:
            !model.editing.value &&
            latestInput?.authorUID === data?.conversation.viewer.uid &&
            (editDisabledReason || canEditLast)
              ? editLast
              : undefined,
          editDisabledReason,
          regenerate: (message: ConversationMessage) => {
            const slot = data?.pendingQueues.find(queue => queue.agentUID === message.authorUID)
            if (!slot || slot.workStatus.state !== 'idle' || slot.inputs.length) return
            changeQueue({
              action: 'regenerate',
              messageID: message.id,
              agentUID: slot.agentUID,
              commandID: crypto.randomUUID()
            })
          }
        }
      : undefined,
    queueError: queue.error || takeBack.error,
    pendingQueueAction: queue.isPending
      ? queue.variables
      : takeBack.isPending
        ? {
            action: 'retract' as const,
            agentUID: takeBack.variables.agentUID,
            messageID: takeBack.variables.input.messageID
          }
        : undefined,
    editConflict:
      queue.error instanceof InternalAPIError &&
      requestErrorCode(queue.error.payload) === 'queue_changed' &&
      !!model.editing.value,
    recovery: { loading: recover.isPending, error: recover.error, refresh: () => recover.mutate(), useSaved }
  }
}

export type ChatCommands = ReturnType<typeof useChatCommands>
