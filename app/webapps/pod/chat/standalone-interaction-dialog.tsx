import { Button, Dialog, DialogContent, DialogFooter, DialogTitle, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import { chatError, interactionQuery, podKeys, type StandaloneInteraction } from '../api'
import { answerPodInteraction } from '../api/generated/sdk.gen'
import { contentError } from '../content-errors'
import { ContentError } from '../content-primitives'
import { refreshConversationQueries } from '../query-cache'
import { ChoiceCard } from './choice-card'
import type { InteractionAnswer } from './room-api'
import type { ClarifyPrompt } from './types'

/** Opens a form question that an external channel linked as `/?interaction=<id>`; opening it never answers. */
export function StandaloneInteractionDialog({
  interactionID,
  onClose
}: {
  interactionID: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const navigate = useNavigate()
  const query = useQuery(interactionQuery(interactionID))

  const answerMutation = useMutation({
    mutationFn: ({ interactionID: id, answer }: { interactionID: string; answer: InteractionAnswer }) =>
      answerPodInteraction({ path: { interaction_id: id }, body: { data: { values: answer.values ?? {} } } }),
    onSuccess: updated => {
      client.setQueryData(podKeys.interaction(interactionID), updated)
      if (updated.conversation_kind === 'native' && updated.conversation_id) {
        void refreshConversationQueries(client, updated.conversation_id)
      }
    },
    onError: error => {
      const code = requestErrorCode(error)
      if (code === 'invalid_form_answer') return
      void client.invalidateQueries({ queryKey: podKeys.interaction(interactionID) })
      if (code !== 'interaction_not_pending') toast.error(requestErrorMessage(contentError(chatError(error))))
    }
  })

  const interaction = query.data

  return (
    <Dialog open onOpenChange={next => !next && !answerMutation.isPending && onClose()}>
      <DialogContent
        className="pod-dialog max-w-lg"
        closeLabel={t('common.close')}
        showCloseButton={!answerMutation.isPending}>
        <DialogTitle>{t('pod.chat_form.dialog_title')}</DialogTitle>
        <div className="pod-dialog-body grid gap-3">
          {query.isPending ? (
            <p role="status" className="text-sm text-fg-secondary">
              {t('pod.content.loading')}
            </p>
          ) : query.isError ? (
            <ContentError error={query.error} retry={() => void query.refetch()} />
          ) : interaction ? (
            <ChoiceCard
              prompt={toPrompt(interaction)}
              interaction={toPrompt(interaction)}
              onAnswer={(id, answer) => answerMutation.mutateAsync({ interactionID: id, answer })}
            />
          ) : null}
        </div>
        <DialogFooter>
          {interaction?.conversation_kind === 'native' && interaction.conversation_id && (
            <Button
              variant="outline"
              size="sm"
              disabled={answerMutation.isPending}
              onClick={() => {
                onClose()
                void navigate({ to: podLocation(`/conversations/${interaction.conversation_id}`).pathname })
              }}>
              {t('pod.chat_action_card.open_conversation', { defaultValue: 'Open conversation' })}
            </Button>
          )}
          <Button variant="ghost" size="sm" disabled={answerMutation.isPending} onClick={onClose}>
            {t('common.close')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function toPrompt(interaction: StandaloneInteraction): ClarifyPrompt {
  const state = interaction.state === 'answered' || interaction.state === 'superseded' ? interaction.state : 'pending'
  return {
    tool_call_id: '',
    interaction_id: interaction.interaction_id,
    question: interaction.question,
    choices: [],
    allow_free_text: false,
    fields: interaction.fields,
    state,
    answer_text: interaction.answer_text,
    answered_by_name: interaction.answered_by_name,
    answered_by_uid: interaction.answered_by_uid
  }
}
