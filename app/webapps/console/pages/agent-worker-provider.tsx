import { useMutation, Link } from '../tenant-context'
import { Button, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, toast } from '@ankole/uikit'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { ErrorBlock } from '../../common/error-block'
import type { AgentItem } from '../api/agents'
import { assignAgentWorkerProviderMutation } from '../api/v2/generated/@tanstack/react-query.gen'
import type { WorkerProvider } from '../state/worker-provider-editor-model'
import { FormSection, LabeledField, ReadOnlyValue } from '../console-form'

export function WorkerProviderSelect({
  providers,
  value,
  onChange,
  id,
  'aria-describedby': ariaDescribedBy,
  'aria-invalid': ariaInvalid,
  ...props
}: {
  providers: WorkerProvider[]
  value: string
  onChange: (value: string) => void
  id?: string
  required?: boolean
  'aria-describedby'?: string
  'aria-invalid'?: boolean
}) {
  const { t } = useTranslation()
  return (
    <Select
      {...props}
      value={value}
      onValueChange={next => {
        if (next) onChange(next)
      }}>
      <SelectTrigger
        aria-describedby={ariaDescribedBy}
        aria-invalid={ariaInvalid}
        aria-label={t('console.worker_providers.provider')}
        className="w-full"
        id={id}>
        <SelectValue placeholder={t('console.worker_providers.select')} />
      </SelectTrigger>
      <SelectContent>
        {providers
          .filter(provider => provider.selectable)
          .map(provider => (
            <SelectItem key={provider.provider_id} value={provider.provider_id}>
              {provider.display_name} ({provider.provider_id})
            </SelectItem>
          ))}
      </SelectContent>
    </Select>
  )
}

export function AgentWorkerProvider({ agent, providers }: { agent: AgentItem; providers: WorkerProvider[] }) {
  const { t } = useTranslation()
  const [providerID, setProviderID] = useState('')
  const assign = useMutation({
    ...assignAgentWorkerProviderMutation(),
    onSuccess: () => {
      toast.success(t('console.worker_providers.assigned'))
    }
  })
  const assignedID = agent.worker_provider_id ?? assign.data?.provider_id
  const selected = providers.find(provider => provider.provider_id === assignedID)

  return (
    <FormSection
      title={t('console.worker_providers.provider')}
      description={t(`console.worker_providers.${assignedID ? 'agent_hint' : 'legacy_hint'}`)}>
      <ErrorBlock error={assign.error} />
      {assignedID ? (
        <ReadOnlyValue>
          <Link className="link" to={`/worker-providers/${encodeURIComponent(assignedID)}`}>
            {selected ? `${selected.display_name} (${assignedID})` : assignedID}
          </Link>
        </ReadOnlyValue>
      ) : (
        <>
          <LabeledField label={t('console.worker_providers.provider')} required>
            <WorkerProviderSelect providers={providers} value={providerID} onChange={setProviderID} />
          </LabeledField>
          <Button
            className="justify-self-start"
            type="button"
            size="sm"
            disabled={!providerID || assign.isPending}
            onClick={() =>
              assign.mutate({ path: { agent_uid: agent.uid }, body: { data: { provider_id: providerID } } })
            }>
            {t('console.worker_providers.assign')}
          </Button>
        </>
      )}
    </FormSection>
  )
}
