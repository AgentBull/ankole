import { Button, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Textarea, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  classifyWorkAccessMutation,
  listPrincipalsOptions,
  listWorkAccessReviewsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { ListWorkAccessReviewsResponse } from '../api/v2/generated/types.gen'
import { fromDocument } from '../api/json-api'
import { ErrorBlock } from '../../common/error-block'
import { requestErrorMessage } from '../../common/request-errors'
import { LabeledField } from '../console-form'
import { AgentLink } from '../console-list-page'
import { SinglePrincipalPicker } from '../principal-picker'
import { AccessReviewModel } from '../state/access-review-model'
import { principalLabel } from '../state/principal-label'

type HumanWorkItem = ListWorkAccessReviewsResponse['work'][number]

function humanizeToken(value: string): string {
  return value
    .replace(/[._-]+/g, ' ')
    .trim()
    .replace(/^\w/, char => char.toUpperCase())
}

export function WorkAccessReview() {
  const { t } = useTranslation()
  const work = useQuery(listWorkAccessReviewsOptions())
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
  const principals = useQuery({
    ...listPrincipalsOptions({ query: { include_disabled: true } }),
    select: data => fromDocument(data)
  })
  const classify = useMutation({
    ...classifyWorkAccessMutation(),
    onSuccess: () => {
      model.reason.value = ''
      toast.success(t('console.human_access.saved'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const currentHuman = work.human_uid ? principals.data?.find(person => person.id === work.human_uid) : undefined
  const currentHumanLabel = currentHuman ? principalLabel(currentHuman) : work.human_uid
  const authorityKindLabel = t('console.human_access.authority_kind', { defaultValue: 'Authority type' })
  const responsibleHumanLabel = t('console.human_access.responsible_human', { defaultValue: 'Responsible person' })

  return (
    <div className="my-4 grid gap-3 border-t border-border pt-4">
      <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
        <span>{humanizeToken(work.kind)}</span>
        <span aria-hidden>·</span>
        <AgentLink uid={work.agent_uid} />
        <span aria-hidden>·</span>
        <span>{t(`console.status.${work.status}`, { defaultValue: humanizeToken(work.status) })}</span>
      </p>
      <code className="text-xs break-all text-muted-foreground">{work.id}</code>
      {work.human_uid ? (
        <p className="text-sm break-all">
          {t('console.human_access.authority')}:{' '}
          <span className={currentHuman ? 'font-medium' : 'font-mono text-xs'} title={work.human_uid}>
            {currentHumanLabel}
          </span>
        </p>
      ) : null}
      {work.can_reauthorize ? (
        <>
          <LabeledField label={authorityKindLabel}>
            <Select
              value={model.authorizationKind.value}
              onValueChange={value => {
                model.authorizationKind.value = value === 'service' ? 'service' : 'human'
              }}>
              <SelectTrigger aria-label={authorityKindLabel}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="human">{t('console.principals.type_human')}</SelectItem>
                {work.authorization_kind !== 'human' ? (
                  <SelectItem value="service">{t('console.human_access.service')}</SelectItem>
                ) : null}
              </SelectContent>
            </Select>
          </LabeledField>
          {model.authorizationKind.value === 'human' ? (
            <LabeledField label={responsibleHumanLabel} required>
              <SinglePrincipalPicker
                ariaLabel={responsibleHumanLabel}
                candidates={(principals.data ?? [])
                  .filter(person => person.type === 'human' && person.status === 'active')
                  .map(person => ({ id: person.id, label: principalLabel(person), description: person.email }))}
                error={principals.error}
                isLoading={principals.isLoading}
                placeholder={t('console.brain.select_principal')}
                required
                value={model.humanUID.value}
                onChange={uid => {
                  model.humanUID.value = uid
                }}
              />
            </LabeledField>
          ) : null}
          <LabeledField label={t('console.human_access.reason')} required>
            <Textarea
              rows={2}
              value={model.reason.value}
              onChange={event => {
                model.reason.value = event.target.value
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
                  data: {
                    kind: work.kind,
                    id: work.id,
                    authorization_kind: model.authorizationKind.value,
                    human_uid: model.authorizationKind.value === 'human' ? model.humanUID.value.trim() : null,
                    reason: model.reason.value.trim()
                  }
                }
              })
            }>
            {t('console.human_access.classify')}
          </Button>
        </>
      ) : null}
    </div>
  )
}
