import {
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Textarea,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebHumanAccessControllerUnresolvedWorkOptions,
  ankoleWebHumanAccessControllerClassifyWorkMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { HumanWorkItem } from '../api/generated/types.gen'
import { AccessReviewModel } from '../state/access-review-model'
import { LabeledField } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'

export function WorkAccessReview() {
  const { t } = useTranslation()
  const work = useQuery(ankoleWebHumanAccessControllerUnresolvedWorkOptions())
  return (
    <details className="border border-border p-4">
      <summary className="cursor-pointer text-sm font-medium">{t('console.human_access.legacy_work')}</summary>
      <p className="my-3 text-sm text-muted-foreground">{t('console.human_access.legacy_hint')}</p>
      <ErrorBlock error={work.error} />
      {work.isLoading ? <p role="status">{t('common.loading')}</p> : null}
      {work.data?.work.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('console.human_access.no_legacy')}</p>
      ) : null}
      {work.data?.work.map(item => (
        <WorkReviewRow key={`${item.kind}:${item.id}`} work={item} />
      ))}
    </details>
  )
}

function WorkReviewRow({ work }: { work: HumanWorkItem }) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AccessReviewModel)
  const queryClient = useQueryClient()
  const classify = useMutation({
    ...ankoleWebHumanAccessControllerClassifyWorkMutation(),
    onSuccess: () => {
      void queryClient.invalidateQueries()
      toast.success(t('console.human_access.saved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  return (
    <div className="my-4 grid gap-3 border-t border-border pt-4">
      <p className="text-sm">
        {work.kind} · {work.agent_uid} · {work.status}
      </p>
      <code className="text-xs break-all">{work.id}</code>
      <LabeledField label={t('console.human_access.authority')}>
        <Select
          value={model.authorizationKind.value}
          onValueChange={value => {
            model.authorizationKind.value = value === 'service' ? 'service' : 'human'
          }}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="human">{t('console.principals.type_human')}</SelectItem>
            <SelectItem value="service">{t('console.human_access.service')}</SelectItem>
          </SelectContent>
        </Select>
      </LabeledField>
      {model.authorizationKind.value === 'human' ? (
        <LabeledField label={t('console.principals.uid')}>
          <Input
            value={model.humanUID.value}
            onChange={e => {
              model.humanUID.value = e.target.value
            }}
          />
        </LabeledField>
      ) : null}
      <LabeledField label={t('console.human_access.reason')}>
        <Textarea
          rows={2}
          value={model.reason.value}
          onChange={e => {
            model.reason.value = e.target.value
          }}
        />
      </LabeledField>
      <Button
        type="button"
        className="justify-self-start"
        disabled={
          classify.isPending ||
          !model.hasReason.value ||
          (model.authorizationKind.value === 'human' && !model.humanUID.value.trim())
        }
        onClick={() =>
          classify.mutate({
            body: {
              kind: work.kind,
              id: work.id,
              authorization_kind: model.authorizationKind.value,
              human_uid: model.authorizationKind.value === 'human' ? model.humanUID.value.trim() : null,
              reason: model.reason.value.trim()
            }
          })
        }>
        {t('console.human_access.classify')}
      </Button>
    </div>
  )
}
