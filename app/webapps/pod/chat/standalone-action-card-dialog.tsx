import { Button, Dialog, DialogContent, DialogFooter, DialogTitle, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { actionCardQuery, chatError, podKeys, type StandaloneActionCard } from '../api'
import { resolvePodActionCard } from '../api/generated/sdk.gen'
import { contentKeys } from '../content-api'
import { contentError } from '../content-errors'
import { ContentError } from '../content-primitives'
import { refreshConversationQueries } from '../query-cache'
import { ActionCardView } from './action-card-view'
import type { ActionCardDecision } from './room-api'
import type { ActionCardState } from './types'

export function StandaloneActionCardDialog({ cardID, onClose }: { cardID: string; onClose: () => void }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const navigate = useNavigate()
  const query = useQuery(actionCardQuery(cardID))

  const resolveMutation = useMutation({
    mutationFn: ({ cardID: targetCardID, decision }: { cardID: string; decision: ActionCardDecision }) =>
      resolvePodActionCard({ path: { card_id: targetCardID }, body: { data: { decision } } }),
    onSuccess: updated => {
      client.setQueryData(podKeys.actionCard(cardID), updated)
      if (updated.conversation_kind === 'native') {
        void refreshConversationQueries(client, updated.conversation_id)
      }
      if (updated.target_node_id) {
        void client.invalidateQueries({ queryKey: contentKeys.page(updated.target_node_id) })
      }
    },
    onError: error => {
      void client.invalidateQueries({ queryKey: podKeys.actionCard(cardID) })
      if (requestErrorCode(error) !== 'action_card_not_pending') {
        toast.error(requestErrorMessage(contentError(chatError(error))))
      }
    }
  })

  const card = query.data

  return (
    <Dialog open onOpenChange={next => !next && !resolveMutation.isPending && onClose()}>
      <DialogContent
        className="pod-dialog max-w-lg"
        closeLabel={t('common.close')}
        showCloseButton={!resolveMutation.isPending}>
        <DialogTitle>{t('pod.chat_action_card.dialog_title', { defaultValue: 'Action approval' })}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          {query.isPending ? (
            <p role="status" className="text-sm text-fg-secondary">
              {t('pod.content.loading')}
            </p>
          ) : query.isError ? (
            <ContentError error={query.error} retry={() => void query.refetch()} />
          ) : card ? (
            <ActionCardView
              card={toActionCardState(card)}
              onResolve={(id, decision) => resolveMutation.mutateAsync({ cardID: id, decision })}
            />
          ) : null}
        </div>
        <DialogFooter>
          {card?.conversation_kind === 'native' && (
            <Button
              variant="outline"
              size="sm"
              disabled={resolveMutation.isPending}
              onClick={() => {
                onClose()
                void navigate({ to: podLocation(`/conversations/${card.conversation_id}`).pathname })
              }}>
              {t('pod.chat_action_card.open_conversation', { defaultValue: 'Open conversation' })}
            </Button>
          )}
          <Button variant="ghost" size="sm" disabled={resolveMutation.isPending} onClick={onClose}>
            {t('common.close')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function toActionCardState(card: StandaloneActionCard): ActionCardState {
  const status =
    card.status === 'executed' || card.status === 'stale' || card.status === 'cancelled' ? card.status : 'prepared'
  return {
    card_id: card.card_id,
    interaction_id: card.interaction_id,
    action_kind: card.action_kind,
    summary: card.summary,
    target_node_id: card.target_node_id,
    payload: card.payload,
    status,
    resolved_by_uid: card.resolved_by_uid,
    resolved_by_name: card.resolved_by_name,
    resolved_at: card.resolved_at,
    resolution_note: card.resolution_note
  }
}
