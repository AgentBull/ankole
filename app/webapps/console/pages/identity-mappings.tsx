import { principalLabel } from '../state/principal-label'
import {
  Button,
  buttonVariants,
  cn,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiUserReceivedLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { useNavigate } from '@tanstack/react-router'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import {
  bindIdentityMappingRequestMutation,
  createIdentityMappingMutation,
  deleteIdentityMappingRequestMutation,
  listIdentityMappingRequestsOptions,
  listPrincipalsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { IdentityMappingRequest } from '../api/v2/generated/types.gen'
import { type Flat, fromDocument } from '../api/json-api'
import type { PrincipalRecord } from './principals'
import { ConfirmDeleteButton, LabeledField, ResourceEditorPage } from '../console-form'
import { LIST_REFRESH_MS } from '../refresh-intervals'
import { ResourceListPage, ResourceSearch, SubNav } from '../console-list-page'
import { formatConsoleDate } from '../console-primitives'
import { SinglePrincipalPicker } from '../principal-picker'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

type IdentityMappingRequestRecord = Flat<IdentityMappingRequest>

const mappingErrorCodes = ['not_human', 'principal_disabled', 'platform_subject_already_bound']

/** Localizes the domain refusals of a bind; other failures keep their message. */
function mappingErrorMessage(t: TFunction, error: unknown): string {
  const code = requestErrorCode(error)
  return code && mappingErrorCodes.includes(code)
    ? t(`console.identity_mappings.error_${code}`)
    : requestErrorMessage(error)
}

/** Sibling views of the "Identity" nav area: providers and the pending-mapping queue. */
export function IdentitySubNav() {
  const { t } = useTranslation()
  return (
    <SubNav
      ariaLabel={t('console.identity_mappings.sections_aria')}
      items={[
        { to: '/identity', label: t('console.identity.title'), end: true },
        { to: '/identity/mappings', label: t('console.identity_mappings.title') }
      ]}
    />
  )
}

export function IdentityMappingsPage() {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  // The operator often sits on this queue waiting for a sender's first
  // message, so the list refreshes itself like the other live queues.
  const requests = useQuery({
    ...listIdentityMappingRequestsOptions(),
    select: data => fromDocument(data),
    refetchInterval: LIST_REFRESH_MS
  })
  const principals = useQuery({ ...listPrincipalsOptions(), select: data => fromDocument(data) })
  // Only a person can own an IM sender; agent and system principals are not bind targets.
  const humanPrincipals = (principals.data ?? []).filter(principal => principal.type === 'human')
  const [bindTarget, setBindTarget] = useState<IdentityMappingRequestRecord>()
  const [bindOpen, setBindOpen] = useState(false)

  const rows = (requests.data ?? []).filter(request =>
    matchesResourceSearch(
      searchQuery,
      request.display_name,
      request.provider,
      request.external_id,
      request.email,
      request.mobile
    )
  )

  const dismiss = useMutation({
    ...deleteIdentityMappingRequestMutation(),
    onSuccess: () => {
      toast.success(t('console.identity_mappings.dismissed'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.identity_mappings.title')}
      description={t('console.identity_mappings.description')}
      createTo="new"
      createLabel={t('console.identity_mappings.new')}
      columns={[
        t('console.identity_mappings.sender'),
        t('console.identity_mappings.provider'),
        t('console.identity_mappings.external_id'),
        t('console.identity_mappings.contact'),
        t('console.identity_mappings.last_seen')
      ]}
      isLoading={requests.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.identity_mappings.empty_title')}
      emptyIcon={<RiUserReceivedLine aria-hidden />}
      emptyDescription={t('console.identity_mappings.empty_description')}
      error={requests.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      subNav={<IdentitySubNav />}
      toolbar={
        <ResourceSearch
          label={t('console.identity_mappings.search')}
          placeholder={t('console.identity_mappings.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }
      footer={
        <BindMappingDialog
          open={bindOpen}
          request={bindTarget}
          principals={humanPrincipals}
          principalsError={principals.error}
          principalsLoading={principals.isLoading}
          onOpenChange={setBindOpen}
        />
      }>
      {rows.map(request => (
        <TableRow key={request.id}>
          <TableCell>{request.display_name || request.external_id}</TableCell>
          <TableCell>{request.provider}</TableCell>
          <TableCell>
            <span className="block max-w-48 truncate font-mono text-xs" title={request.external_id}>
              {request.external_id}
            </span>
          </TableCell>
          <TableCell>{[request.email, request.mobile].filter(Boolean).join(' · ') || '—'}</TableCell>
          <TableCell>{formatConsoleDate(request.updated_at)}</TableCell>
          <TableCell className="text-right">
            <div className="flex justify-end gap-2">
              <Button
                size="sm"
                type="button"
                variant="outline"
                onClick={() => {
                  setBindTarget(request)
                  setBindOpen(true)
                }}>
                {t('console.identity_mappings.bind')}
              </Button>
              <ConfirmDeleteButton
                confirm={{
                  title: t('console.identity_mappings.dismiss_title'),
                  description: t('console.identity_mappings.dismiss_description', { id: request.external_id }),
                  confirmLabel: t('console.identity_mappings.dismiss')
                }}
                label={t('console.identity_mappings.dismiss')}
                pending={dismiss.isPending}
                size="sm"
                onConfirm={() => dismiss.mutate({ path: { id: request.id } })}
              />
            </div>
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

/**
 * Proactive mapping: bind a platform account to a user before the person ever
 * writes, so their first message never enters the manual-review queue.
 */
export function IdentityMappingCreatePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const principals = useQuery({ ...listPrincipalsOptions(), select: data => fromDocument(data) })
  const humanPrincipals = (principals.data ?? []).filter(principal => principal.type === 'human')
  const [provider, setProvider] = useState('')
  const [externalID, setExternalID] = useState('')
  const [principalUID, setPrincipalUID] = useState<string>()
  const [validationError, setValidationError] = useState<string>()

  const create = useMutation({
    ...createIdentityMappingMutation(),
    onSuccess: () => {
      toast.success(t('console.identity_mappings.created'))
      void navigate({ to: '/identity/mappings' })
    }
  })

  const submit = () => {
    setValidationError(undefined)
    const trimmedProvider = provider.trim()
    const trimmedExternalID = externalID.trim()
    if (!trimmedProvider) {
      setValidationError(t('console.identity_mappings.provider_required'))
      return
    }
    if (!trimmedExternalID) {
      setValidationError(t('console.identity_mappings.external_id_required'))
      return
    }
    if (!principalUID) {
      setValidationError(t('console.identity_mappings.principal_required'))
      return
    }
    create.mutate({
      body: { data: { provider: trimmedProvider, external_id: trimmedExternalID, principal_uid: principalUID } }
    })
  }

  return (
    <ResourceEditorPage
      title={t('console.identity_mappings.new')}
      description={t('console.identity_mappings.new_description')}
      backTo="/identity/mappings"
      dirty={Boolean(provider.trim() || externalID.trim() || principalUID)}
      validationError={validationError}
      error={create.error ? mappingErrorMessage(t, create.error) : principals.error}
      submitting={create.isPending}
      onSubmit={submit}>
      <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
        <LabeledField
          label={t('console.identity_mappings.provider')}
          description={t('console.identity_mappings.provider_hint')}
          required>
          <Input required value={provider} onChange={event => setProvider(event.target.value)} />
        </LabeledField>
        <LabeledField
          label={t('console.identity_mappings.external_id')}
          description={t('console.identity_mappings.external_id_hint')}
          required>
          <Input required value={externalID} onChange={event => setExternalID(event.target.value)} />
        </LabeledField>
      </div>
      <LabeledField label={t('console.identity_mappings.picker_label')} required>
        <SinglePrincipalPicker
          ariaLabel={t('console.identity_mappings.picker_label')}
          placeholder={t('console.identity_mappings.picker_placeholder')}
          candidates={humanPrincipals.map(principal => ({
            id: principal.id,
            label: principalLabel(principal),
            description: principal.email ?? principal.handle
          }))}
          disabled={create.isPending}
          error={principals.error}
          isLoading={principals.isLoading}
          value={principalUID ?? ''}
          onChange={id => setPrincipalUID(id || undefined)}
        />
      </LabeledField>
    </ResourceEditorPage>
  )
}

function BindMappingDialog({
  onOpenChange,
  open,
  principals,
  principalsError,
  principalsLoading,
  request
}: {
  onOpenChange: (open: boolean) => void
  open: boolean
  principals: PrincipalRecord[]
  principalsError: unknown
  principalsLoading: boolean
  request: IdentityMappingRequestRecord | undefined
}) {
  const { t } = useTranslation()
  const [selectedUID, setSelectedUID] = useState<string>()
  const selected = principals.find(principal => principal.id === selectedUID)
  const senderName = request ? request.display_name || request.external_id : ''

  useEffect(() => {
    if (open) setSelectedUID(undefined)
  }, [open, request?.id])

  const bind = useMutation({
    ...bindIdentityMappingRequestMutation(),
    onSuccess: () => {
      toast.success(t('console.identity_mappings.bound', { name: selected?.display_name ?? selectedUID }))
      onOpenChange(false)
    },
    onError: error => toast.error(mappingErrorMessage(t, error))
  })

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent closeLabel={t('common.close')}>
        <DialogHeader>
          <DialogTitle>{t('console.identity_mappings.bind_title')}</DialogTitle>
          <DialogDescription>
            {t('console.identity_mappings.bind_description', { name: senderName, provider: request?.provider })}
          </DialogDescription>
        </DialogHeader>
        <SinglePrincipalPicker
          ariaLabel={t('console.identity_mappings.picker_label')}
          placeholder={t('console.identity_mappings.picker_placeholder')}
          candidates={principals.map(principal => ({
            id: principal.id,
            label: principalLabel(principal),
            description: principal.email ?? principal.handle
          }))}
          disabled={bind.isPending}
          error={principalsError}
          isLoading={principalsLoading}
          value={selectedUID ?? ''}
          onChange={id => setSelectedUID(id || undefined)}
        />
        <DialogFooter>
          <DialogClose className={cn(buttonVariants({ size: 'sm', variant: 'ghost' }))}>
            {t('common.cancel')}
          </DialogClose>
          <Button
            disabled={!request || !selectedUID || bind.isPending}
            size="sm"
            type="button"
            onClick={() =>
              request &&
              selectedUID &&
              bind.mutate({ path: { id: request.id }, body: { data: { principal_uid: selectedUID } } })
            }>
            {t('console.identity_mappings.bind_confirm')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
