import { uuidV4 } from '@agentbull/active-support'
import { useIsMutating, useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from '@ankole/uikit'
import { t } from 'i18next'
import { useEffect, useSyncExternalStore } from 'react'
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
import { ensurePodPersonalAssistant } from './api/generated/sdk.gen'
import type { PodAgentsResponse } from './api/generated/types.gen'
import { restoreConversationFiles } from './native-transfers'
import { modelSelectionKey } from './model-controls'
import { acceptConversationResult, refreshConversationQueries } from './query-cache'
import {
  ChatModel,
  chatCommandPolicy,
  chatRecipientAvailable,
  draftLinks,
  draftMentions,
  issueRecipientUID,
  queuedInputs,
  resolveFollowUpDeliveryModes,
  type ChatEditSnapshot,
  type FollowUpBehavior
} from './state/chat'
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
  personalAssistant = false,
  callableAgentUIDs,
  refresh,
  onInlineEditSettled
}: {
  model: Model
  drafts: ChatDrafts
  conversationID?: string
  pageID?: string
  accessScope?: 'participants' | 'anchor_page'
  data?: ConversationDetail
  agentUID: string
  agentsError: boolean
  personalAssistant?: boolean
  callableAgentUIDs: string[]
  refresh(): Promise<ConversationDetail | undefined>
  onInlineEditSettled?(): void
}) {
  const client = useQueryClient()
  const queueKey = [...podKeys.detail(conversationID ?? ''), 'queue-command']
  const queuePending = useIsMutating({ mutationKey: queueKey }) > 0
  useIsMutating({ mutationKey: modelSelectionKey(conversationID ?? '') })
  const send = useMutation({
    mutationFn: async ({
      submission,
      owner,
      create
    }: {
      submission: MessageSubmission
      owner: Model
      create: boolean
    }) => {
      if (create && personalAssistant && !submission.agentUID) {
        const assistant = await ensurePodPersonalAssistant()
        client.setQueryData<PodAgentsResponse>(podKeys.agents, current =>
          current ? { ...current, personalAssistant: assistant } : current
        )
        submission.agentUID = assistant.uid
        owner.resolvePendingAgent(submission.messageID, assistant.uid)
      }
      try {
        return await postMessage(submission, create)
      } catch (failure) {
        if (
          !create &&
          submission.deliveryMode === 'steer' &&
          failure instanceof InternalAPIError &&
          requestErrorCode(failure.payload) === 'requires_queue_for_profile'
        ) {
          void client.invalidateQueries({ queryKey: modelSelectionKey(submission.conversationID), exact: false })
          submission.deliveryMode = 'queue'
          return postMessage(submission, false)
        }
        throw failure
      }
    },
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
      owner.accepted({ ...submission, conversationID: data.conversation.id })
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
        const idleAgentUIDs = data.pendingQueues
          .filter(slot => slot.workStatus.state === 'idle')
          .map(slot => slot.agentUID)
        const closed = model.editSaved(
          command.messageID,
          command.text,
          command.links ? draftLinks(command.links) : [],
          idleAgentUIDs
        )
        if (closed && command.action === 'edit_last') onInlineEditSettled?.()
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
  const callableSet = new Set(callableAgentUIDs)
  const issueAgentUID = issueRecipientUID(data, callableAgentUIDs)
  useEffect(() => {
    if (issueAgentUID && !model.targetAgentUID.peek()) model.targetAgentUID.value = issueAgentUID
  }, [model, issueAgentUID])
  const sending = (send.isPending && send.variables.owner === model) || model.pending.value?.state === 'sending'
  const working =
    !!data &&
    (data.pendingQueues.some(queue => queue.workStatus.state !== 'idle') ||
      data.conversation.agents.some(agent => model.liveStreams.value[agent.uid]))
  const mentionedAgentUIDs = model.mentionedAgentUIDs.value
  const addressedUIDs = data
    ? data.conversation.roomMode === 'group'
      ? model.targetAgentUID.value || mentionedAgentUIDs.length > 0
        ? [...new Set([...(model.targetAgentUID.value ? [model.targetAgentUID.value] : []), ...mentionedAgentUIDs])]
        : data.conversation.agents
            .filter(agent => agent.active && agent.mayIntervene && callableSet.has(agent.uid))
            .map(agent => agent.uid)
      : [model.targetAgentUID.value || agentUID || data.conversation.agents[0]?.uid].filter(
          (uid): uid is string => !!uid
        )
    : []
  const targetWorking =
    !!data &&
    addressedUIDs.some(uid => {
      const slot = data.pendingQueues.find(queue => queue.agentUID === uid)
      return (
        (!!slot && slot.workStatus.state !== 'idle') ||
        !!model.liveStreams.value[uid] ||
        model.activities.value[uid]?.state === 'active'
      )
    })
  const targetPaused =
    !!data &&
    addressedUIDs.some(uid => {
      const slot = data.pendingQueues.find(queue => queue.agentUID === uid)
      return !!slot && slot.paused && queuedInputs(slot).length > 0
    })
  const checkProfileMismatch = () =>
    !!conversationID &&
    addressedUIDs.some(uid => {
      const selection = client.getQueryData<{ profile?: string | null; activeProfile?: string | null }>([
        ...modelSelectionKey(conversationID),
        uid
      ])
      return !!selection?.activeProfile && selection.activeProfile !== (selection.profile ?? 'primary')
    })
  const hasProfileMismatch = useSyncExternalStore(
    onStoreChange => (conversationID ? client.getQueryCache().subscribe(onStoreChange) : () => {}),
    checkProfileMismatch,
    checkProfileMismatch
  )
  const canSteerTarget = !hasProfileMismatch
  const deliveryModes = resolveFollowUpDeliveryModes({
    working: targetWorking,
    paused: targetPaused,
    canSteer: canSteerTarget,
    followUpBehavior: model.followUpBehavior.value
  })
  const queueEditing = model.editing.value?.kind === 'queue' ? model.editing.value : undefined
  const answeringID = model.answeringInteractionID.value
  const recipientUID =
    data?.pendingInteractions.find(question => question.interaction_id === answeringID)?.agentUID ??
    queueEditing?.agentUID ??
    model.targetAgentUID.value
  const recipientAvailable =
    !data ||
    (!!answeringID && !!recipientUID && callableSet.has(recipientUID)) ||
    chatRecipientAvailable(recipientUID, data.conversation.agents, callableAgentUIDs)
  const hasSubmission = queueEditing
    ? model.hasText.value || queueEditing.hasAttachments
    : model.hasContent.value && model.attachments.canSend.value
  const computePolicy = (targetUID: string) => {
    const slot = data?.pendingQueues.find(queue => queue.agentUID === targetUID)
    const commandPolicy = chatCommandPolicy({
      sending,
      queuePending,
      modelSaving:
        !!conversationID && client.isMutating({ mutationKey: [...modelSelectionKey(conversationID), targetUID] }) > 0,
      available: conversationID
        ? !!data &&
          (data.conversation.roomMode === 'group' ||
            data.conversation.accessScope === 'anchor_page' ||
            data.conversation.agents.some(
              agent => (!targetUID || agent.uid === targetUID) && agent.active && callableSet.has(agent.uid)
            ))
        : (!!agentUID || personalAssistant) && !agentsError,
      working: !!slot && (slot.workStatus.state !== 'idle' || !!model.liveStreams.value[targetUID]),
      hasQueued: !!slot?.inputs.length,
      hasSubmission
    })
    return { ...commandPolicy, recipientAvailable, canSubmit: commandPolicy.canSubmit && recipientAvailable }
  }
  const policyCache = new Map<string, ReturnType<typeof computePolicy>>()
  const policy = (targetUID = agentUID) => {
    const cached = policyCache.get(targetUID)
    if (cached) return cached
    const computedPolicy = computePolicy(targetUID)
    policyCache.set(targetUID, computedPolicy)
    return computedPolicy
  }
  const latestInput = data?.latestInput
  const queuedMessageIDs = new Set(
    data?.pendingQueues.flatMap(queue => queuedInputs(queue).map(input => input.messageID)) ?? []
  )
  const editableByMessageID = new Map<
    string,
    { messageID: string; agentUIDs: string[]; supersededByParticipant: boolean }
  >()
  if (data) {
    for (const entry of data.editableInputs ?? []) {
      editableByMessageID.set(entry.messageID, entry)
    }
    if (editableByMessageID.size === 0 && latestInput && latestInput.authorUID === data.conversation.viewer.uid) {
      editableByMessageID.set(latestInput.messageID, {
        messageID: latestInput.messageID,
        agentUIDs: latestInput.agentUIDs,
        supersededByParticipant: false
      })
    }
  }
  const editableMeta = (message: ConversationMessage) => {
    if (
      !data ||
      message.authorType !== 'human' ||
      message.kind !== 'message' ||
      message.authorUID !== data.conversation.viewer.uid ||
      queuedMessageIDs.has(message.id)
    ) {
      return undefined
    }
    return editableByMessageID.get(message.id)
  }
  const editDisabledReasonFor = (message: ConversationMessage): string | undefined => {
    const meta = editableMeta(message)
    if (!meta) return undefined
    if (meta.supersededByParticipant) return t('pod.chat.errors.reply_unavailable')
    if (meta.agentUIDs.length === 0) return t('pod.chat_timeline.no_agent_edit')
    if (meta.agentUIDs.length > 1) return t('pod.chat_timeline.multi_agent_edit')
    return undefined
  }
  const resetEditErrors = () => {
    if (!queue.isPending) queue.reset()
    if (!recover.isPending) recover.reset()
  }
  const cancelEdit = () => {
    model.cancelEdit()
    resetEditErrors()
  }
  const computeCanEditMessage = (message: ConversationMessage): boolean => {
    const meta = editableMeta(message)
    if (!meta || meta.supersededByParticipant || meta.agentUIDs.length !== 1) return false
    const targetUID = meta.agentUIDs[0]!
    const slot = data?.pendingQueues.find(queue => queue.agentUID === targetUID)
    return (
      !!slot &&
      callableSet.has(targetUID) &&
      !!data?.conversation.agents.some(agent => agent.uid === targetUID && agent.active) &&
      policy(targetUID).canQueue('edit_last')
    )
  }
  const editableMessageIDs =
    data?.messages.filter(message => computeCanEditMessage(message)).map(message => message.id) ?? []
  const editableMessageIDSet = new Set(editableMessageIDs)
  const canEditMessage = (message: ConversationMessage): boolean => editableMessageIDSet.has(message.id)
  const latestMessage = latestInput && data?.messages.find(message => message.id === latestInput.messageID)
  const editDisabledReason = latestMessage
    ? editDisabledReasonFor(latestMessage)
    : latestInput
      ? latestInput.agentUIDs.length === 0
        ? t('pod.chat_timeline.no_agent_edit')
        : latestInput.agentUIDs.length > 1
          ? t('pod.chat_timeline.multi_agent_edit')
          : undefined
      : undefined
  const inlineEditing = model.editing.value?.kind === 'last' ? model.editing.value : undefined
  const editRecipientAvailable =
    !inlineEditing ||
    !data ||
    chatRecipientAvailable(inlineEditing.agentUID, data.conversation.agents, callableAgentUIDs)
  const canSubmitEdit =
    !!inlineEditing &&
    editRecipientAvailable &&
    (model.hasEditText.value || inlineEditing.hasAttachments) &&
    policy(inlineEditing.agentUID).canQueue('edit_last')
  const changeQueue = (command: ConversationQueueRequest) => {
    const slot = data?.pendingQueues.find(queue => queue.agentUID === command.agentUID)
    if (!conversationID || !slot || !policy(slot.agentUID).canQueue(command.action)) return
    queue.mutate({
      ...command,
      expectedVersion: command.expectedVersion ?? slot.queueVersion
    })
  }
  const submitEdit = () => {
    if (!canSubmitEdit) return
    const edit = model.editCommand()
    if (edit?.action === 'edit_last') changeQueue(edit)
  }
  const submit = (modeOverride?: FollowUpBehavior) => {
    if (!policy().canSubmit) return
    const edit = model.editing.value?.kind === 'queue' ? model.editCommand() : undefined
    if (edit) changeQueue(edit)
    else {
      const recipientUID = agentUID || (personalAssistant ? (model.pending.peek()?.agentUID ?? '') : '')
      const deliveryMode = modeOverride ?? deliveryModes.primary
      const submission = model.submit(conversationID, recipientUID, () => uuidV4(), deliveryMode)
      // Release the new-chat slot without treating an unconfirmed create as a saved conversation.
      if (!conversationID && !pageID) drafts.remember(model, submission.conversationID)
      send.mutate({
        submission: { ...submission, ...(pageID ? { pageID, accessScope } : {}) },
        owner: model,
        create: !conversationID
      })
    }
  }
  const editMessage = (message: ConversationMessage) => {
    const meta = editableMeta(message)
    if (!meta || queuePending) return
    const reason = editDisabledReasonFor(message)
    if (reason) {
      toast.info(reason)
      return
    }
    if (!canEditMessage(message)) return
    const targetUID = meta.agentUIDs[0]!
    const targetQueue = data?.pendingQueues.find(queue => queue.agentUID === targetUID)
    if (!targetQueue) return
    resetEditErrors()
    model.beginEdit({
      messageID: message.id,
      text: message.text,
      queueVersion: targetQueue.queueVersion,
      kind: 'last',
      hasAttachments: message.attachments.length > 0,
      agentUID: targetQueue.agentUID,
      links: draftLinks(message.links),
      mentions: draftMentions(message.mentions)
    })
  }
  const editQueued = (input: ConversationPendingInput, agentUID: string) => {
    const slot = data?.pendingQueues.find(queue => queue.agentUID === agentUID)
    if (
      slot &&
      callableSet.has(agentUID) &&
      data?.conversation.agents.some(agent => agent.uid === agentUID && agent.active) &&
      policy(agentUID).canQueue('edit')
    ) {
      resetEditErrors()
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
  const editConflict =
    queue.error instanceof InternalAPIError &&
    requestErrorCode(queue.error.payload) === 'queue_changed' &&
    !!model.editing.value
  const inlineEditError =
    model.editing.value?.kind === 'last' && !editConflict && queue.variables?.action === 'edit_last'
      ? queue.error
      : undefined
  return {
    ...policy(),
    canSubmitEdit,
    editRecipientAvailable,
    sending,
    working,
    targetWorking,
    targetPaused,
    canSteerTarget,
    deliveryModes,
    submit,
    submitEdit,
    cancelEdit,
    changeQueue,
    editQueued,
    editableMessageIDs,
    enterBacktrack: () => {
      if (editableMessageIDs.length === 0) return false
      model.startBacktrack(editableMessageIDs.at(-1)!)
      return true
    },
    recallLast: () => {
      if (!data) return
      const lastViewerMsg = data.messages.findLast(
        message =>
          message.authorType === 'human' &&
          message.kind === 'message' &&
          message.authorUID === data.conversation.viewer.uid
      )
      if (!lastViewerMsg) return
      const queued = data.pendingQueues
        .flatMap(queue => queuedInputs(queue).map(input => ({ input, agentUID: queue.agentUID })))
        .findLast(item => item.input.messageID === lastViewerMsg.id)
      if (queued) {
        editQueued(queued.input, queued.agentUID)
        return
      }
      const latestEditable =
        data.messages.findLast(message => canEditMessage(message)) ??
        (editableMeta(lastViewerMsg) ? lastViewerMsg : undefined)
      if (latestEditable) editMessage(latestEditable)
    },
    takeBackQueued: (input: ConversationPendingInput, agentUID: string) => {
      if (model.editing.value?.kind !== 'queue') takeBack.mutate({ input, agentUID })
    },
    takeBackLastQueued: () => {
      if (model.editing.value?.kind === 'queue' || !data) return false
      const messageSeq = new Map(data.messages.map((message, index) => [message.id, message.seq ?? index]))
      const candidates = data.pendingQueues
        .filter(
          slot =>
            (!model.targetAgentUID.value || slot.agentUID === model.targetAgentUID.value) &&
            callableSet.has(slot.agentUID) &&
            data.conversation.agents.some(agent => agent.uid === slot.agentUID && agent.active) &&
            policy(slot.agentUID).canQueue('retract')
        )
        .flatMap(slot =>
          queuedInputs(slot)
            .filter(input => input.authorUID === data.conversation.viewer.uid)
            .map(input => ({ input, agentUID: slot.agentUID }))
        )
      const latest = candidates.reduce<{ input: ConversationPendingInput; agentUID: string } | undefined>(
        (best, item) => {
          if (!best) return item
          return (messageSeq.get(item.input.messageID) ?? -1) >= (messageSeq.get(best.input.messageID) ?? -1)
            ? item
            : best
        },
        undefined
      )
      if (!latest) return false
      takeBack.mutate(latest)
      return true
    },
    canStop: stoppable.length > 0,
    stop: () => {
      if (!data || !policy().canQueue('stop')) return
      const commandID = model.stopID(() => uuidV4())
      void (async () => {
        for (const agentUID of stoppable) {
          await queue.mutateAsync({ action: 'stop', agentUID, commandID })
        }
      })().catch(() => {})
    },
    messageActions: !policy().disabled
      ? {
          canEdit: (message: ConversationMessage) =>
            !!editableMeta(message) && (!!editDisabledReasonFor(message) || canEditMessage(message)),
          edit: !queuePending ? editMessage : undefined,
          editDisabledReason,
          editDisabledReasonFor,
          regenerate: (message: ConversationMessage) => {
            const slot = data?.pendingQueues.find(queue => queue.agentUID === message.authorUID)
            if (!slot || slot.workStatus.state !== 'idle' || slot.inputs.length) return
            changeQueue({
              action: 'regenerate',
              messageID: message.id,
              agentUID: slot.agentUID,
              commandID: uuidV4()
            })
          }
        }
      : undefined,
    queueError: queue.error || takeBack.error,
    inlineEditError,
    pendingQueueAction: queue.isPending
      ? queue.variables
      : takeBack.isPending
        ? {
            action: 'retract' as const,
            agentUID: takeBack.variables.agentUID,
            messageID: takeBack.variables.input.messageID
          }
        : undefined,
    editConflict,
    recovery: { loading: recover.isPending, error: recover.error, refresh: () => recover.mutate(), useSaved }
  }
}

export type ChatCommands = ReturnType<typeof useChatCommands>
