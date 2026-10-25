import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from '@ankole/uikit'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { contentError } from '../content-errors'
import { acceptConversationResult, refreshConversationQueries } from '../query-cache'
import { podKeys, chatError, type ConversationDetail } from '../api'
import {
  updateConversation,
  updateConversationParticipants,
  answerConversationInteraction
} from '../api/generated/sdk.gen'
import type {
  UpdateConversationData,
  UpdateConversationParticipantsData,
  AnswerConversationInteractionData
} from '../api/generated/types.gen'

export type RoomUpdate = NonNullable<UpdateConversationData['body']>['data']
export type ParticipantUpdate = NonNullable<UpdateConversationParticipantsData['body']>['data']
export type InteractionAnswer = NonNullable<AnswerConversationInteractionData['body']>['data']

export function useRoomActions(id: string) {
  const client = useQueryClient()
  const onError = (error: unknown) => {
    toast.error(requestErrorMessage(contentError(chatError(error))))
    void refreshConversationQueries(client, id)
  }
  const onSuccess = async (data: ConversationDetail) => {
    await acceptConversationResult(client, data)
    void refreshConversationQueries(client, id)
  }
  const update = useMutation({
    mutationFn: (data: RoomUpdate) => updateConversation({ path: { id }, body: { data } }),
    onSuccess,
    onError
  })
  const participants = useMutation({
    mutationFn: (data: ParticipantUpdate) => updateConversationParticipants({ path: { id }, body: { data } }),
    onSuccess: () => refreshConversationQueries(client, id),
    onError
  })
  const answer = useMutation({
    mutationFn: ({ interactionID, answer }: { interactionID: string; answer: InteractionAnswer }) =>
      answerConversationInteraction({ path: { id, interaction_id: interactionID }, body: { data: answer } }),
    onSuccess,
    onError: error => {
      if (requestErrorCode(error) === 'interaction_not_pending') void refreshConversationQueries(client, id)
      else onError(error)
    }
  })
  return { update, participants, answer }
}

export const teammatesKey = () => [...podKeys.agents, 'teammates'] as const
