import { flushSync } from 'react-dom'
import { principalLabel } from '../state/principal-label'
import { Badge, Button, Input, Switch, TableCell, TableRow, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiBuildingLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import {
  createTenantMutation,
  deleteTenantMutation,
  getPrivilegedTenantOptions,
  listTenantBrainPacksOptions,
  listTenantsOptions,
  resumeTenantMutation,
  suspendTenantMutation,
  transferSiteAdministrationMutation,
  updateTenantMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import { type Flat, fromDocument } from '../api/json-api'
import type { Tenant as TenantResource } from '../api/v2-site/generated/types.gen'
import { listPrincipalsOptions } from '../api/v2/generated/@tanstack/react-query.gen'
import { clearDataTenant, selectDataTenant } from '../../common/browser-session'
import {
  ConfirmDeleteButton,
  EditorNotFound,
  LabeledField,
  ReadOnlyValue,
  ResourceEditorPage,
  StatusIndicator
} from '../console-form'
import { ResourceListPage, RowViewAction } from '../console-list-page'
import { SinglePrincipalPicker } from '../principal-picker'
import { TenantEditorModel } from '../state/tenant-editor-model'
import { useEditorDraft } from '../use-editor-draft'
import { ErrorBlock } from '../../common/error-block'

type Tenant = Flat<TenantResource>

function tenantState(tenant: Tenant) {
  return tenant.deleting_at ? 'deleting' : tenant.suspended_at ? 'suspended' : 'active'
}

export function TenantsListPage() {
  const { t } = useTranslation()
  const tenants = useQuery({
    ...listTenantsOptions(),
    select: document => fromDocument(document),
    refetchInterval: query => (query.state.data?.data?.some(tenant => tenant.attributes?.deleting_at) ? 5000 : false)
  })
  const privileged = useQuery({ ...getPrivilegedTenantOptions(), select: document => fromDocument(document) })
  const rows = tenants.data ?? []
  return (
    <ResourceListPage
      title={t('console.tenants.title')}
      description={t('console.tenants.description')}
      createTo="/tenants/new"
      createLabel={t('console.tenants.new')}
      columns={[t('console.tenants.name'), t('console.tenants.slug'), t('console.tenants.state')]}
      isLoading={tenants.isLoading}
      isEmpty={!rows.length}
      count={rows.length}
      emptyTitle={t('console.tenants.empty')}
      emptyIcon={<RiBuildingLine aria-hidden />}
      error={tenants.error ?? privileged.error}>
      {rows.map(tenant => (
        <TableRow key={tenant.id}>
          <TableCell>
            <Link data-row-link className="text-foreground" to={`/tenants/${tenant.id}`}>
              {tenant.display_name}
            </Link>
            {privileged.data?.id === tenant.id ? (
              <Badge className="ml-2" variant="secondary">
                {t('console.tenants.privileged')}
              </Badge>
            ) : null}
          </TableCell>
          <TableCell className="font-mono text-xs">{tenant.slug}</TableCell>
          <TableCell>
            <StatusIndicator tone={tenantState(tenant) === 'active' ? 'positive' : 'neutral'}>
              {t(`console.tenants.${tenantState(tenant)}`)}
            </StatusIndicator>
          </TableCell>
          <RowViewAction
            label={t('common.view_details_for', { name: tenant.display_name })}
            to={`/tenants/${tenant.id}`}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function TenantEditorPage() {
  const { tenantID } = useParams({ strict: false })
  return <TenantEditor key={tenantID ?? 'new'} tenantID={tenantID} />
}

function TenantEditor({ tenantID }: { tenantID?: string }) {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(TenantEditorModel)
  const tenants = useQuery({ ...listTenantsOptions(), select: document => fromDocument(document) })
  const brainPacks = useQuery({ ...listTenantBrainPacksOptions(), enabled: !tenantID })
  const privileged = useQuery({ ...getPrivilegedTenantOptions(), select: document => fromDocument(document) })
  const selected = tenants.data?.find(tenant => tenant.id === tenantID)
  const isPrivileged = tenantID === privileged.data?.id
  const source = useMemo(
    () =>
      tenantID
        ? selected && { slug: selected.slug, displayName: selected.display_name, brainPacks: [] }
        : { slug: '', displayName: '', brainPacks: [] },
    [tenantID, selected]
  )
  const status = useEditorDraft(model, {
    sourceKey: tenantID ? `tenant:${tenantID}` : 'new',
    source,
    absent: () => Boolean(tenantID && tenants.isSuccess && !selected)
  })
  const saved = () => {
    toast.success(t('console.tenants.saved'))
  }
  const create = useMutation({
    ...createTenantMutation(),
    onMutate: () => model.captureSave(),
    onSuccess: (response, variables, confirm) => {
      const tenant = fromDocument(response)
      let accepted = false
      flushSync(() => {
        accepted =
          confirm?.({
            slug: tenant.slug,
            displayName: tenant.display_name,
            brainPacks: variables.body.data.attributes?.brain_packs ?? []
          }) ?? false
      })
      if (!accepted) return
      saved()
      if (!model.dirty.value) void navigate({ to: `/tenants/${tenant.id}` })
    }
  })
  const update = useMutation({
    ...updateTenantMutation(),
    onMutate: () => model.captureSave(),
    onSuccess: (response, _variables, confirm) => {
      const tenant = fromDocument(response)
      if (confirm?.({ slug: tenant.slug, displayName: tenant.display_name, brainPacks: [] })) saved()
    }
  })
  const suspend = useMutation({ ...suspendTenantMutation(), onSuccess: saved })
  const resume = useMutation({ ...resumeTenantMutation(), onSuccess: saved })
  const remove = useMutation({
    ...deleteTenantMutation(),
    onMutate: () => window.location.href,
    onSuccess: (_response, _variables, sourceURL) => {
      if (window.location.href !== sourceURL) return
      void navigate({ to: '/tenants' })
    }
  })
  if (status === 'absent') return <EditorNotFound backTo="/tenants" message={t('console.tenants.not_found')} />
  return (
    <ResourceEditorPage
      title={selected?.display_name ?? t('console.tenants.new')}
      description={t('console.tenants.editor_description')}
      backTo="/tenants"
      dirty={model.dirty.value && !remove.isPending}
      supplementaryDirty={model.dirty.value && !remove.isPending}
      error={
        create.error ??
        update.error ??
        remove.error ??
        suspend.error ??
        resume.error ??
        tenants.error ??
        brainPacks.error ??
        privileged.error
      }
      submitting={create.isPending || update.isPending}
      submitUnavailable={status !== 'ready' || Boolean(selected?.deleting_at)}
      submitDisabled={Boolean(tenantID && !model.dirty.value)}
      onSubmit={() => {
        const attributes = { slug: model.slug.value.trim(), display_name: model.displayName.value.trim() }
        if (tenantID) {
          update.mutate({ path: { id: tenantID }, body: { data: { type: 'tenant', id: tenantID, attributes } } })
        } else {
          const brainPacks = model.brainPacks.value
          create.mutate({ body: { data: { type: 'tenant', attributes: { ...attributes, brain_packs: brainPacks } } } })
        }
      }}
      secondary={
        selected && !selected.deleting_at ? (
          <div className="flex flex-wrap items-center gap-2">
            <Button type="button" variant="outline" onClick={() => selectDataTenant(selected.id)}>
              {t('console.tenants.manage')}
            </Button>
            {!isPrivileged && privileged.isSuccess ? (
              <>
                <Button
                  type="button"
                  variant="outline"
                  disabled={suspend.isPending || resume.isPending}
                  onClick={() => (selected.suspended_at ? resume : suspend).mutate({ path: { id: selected.id } })}>
                  {t(selected.suspended_at ? 'console.tenants.resume' : 'console.tenants.suspend')}
                </Button>
                <ConfirmDeleteButton
                  label={t('common.delete')}
                  pending={remove.isPending}
                  confirm={{
                    title: t('console.tenants.delete_title'),
                    description: t('console.tenants.delete_description', { name: selected.display_name }),
                    confirmLabel: t('common.delete')
                  }}
                  onConfirm={() => remove.mutate({ path: { id: selected.id } })}
                />
              </>
            ) : null}
          </div>
        ) : null
      }
      supplementary={
        selected && !isPrivileged && !selected.suspended_at && !selected.deleting_at && privileged.isSuccess ? (
          <TransferAdministration tenant={selected} />
        ) : undefined
      }>
      <fieldset className="contents" disabled={create.isPending}>
        <LabeledField label={t('console.tenants.name')} required>
          <Input
            value={model.displayName.value}
            onChange={event => model.setDisplayName(event.target.value, !tenantID)}
          />
        </LabeledField>
        <LabeledField label={t('console.tenants.slug')} required description={t('console.tenants.slug_hint')}>
          <Input
            value={model.slug.value}
            onChange={event => model.setSlug(event.target.value)}
            pattern="[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?"
            autoComplete="off"
            spellCheck={false}
          />
        </LabeledField>
        {selected ? (
          <LabeledField label={t('console.tenants.state')}>
            <ReadOnlyValue>{t(`console.tenants.${tenantState(selected)}`)}</ReadOnlyValue>
          </LabeledField>
        ) : (
          <div className="grid gap-3">
            <p className="text-sm text-muted-foreground">{t('console.tenants.packs_hint')}</p>
            {brainPacks.data?.map(pack => (
              <label
                key={pack}
                className="flex min-h-11 cursor-pointer items-center justify-between gap-3 border border-border bg-muted/30 px-4 py-2.5 text-sm font-medium text-foreground">
                <span className="font-mono text-xs">{pack}</span>
                <Switch
                  checked={model.brainPacks.value.includes(pack)}
                  onCheckedChange={checked => {
                    model.brainPacks.value = checked
                      ? [...model.brainPacks.value, pack]
                      : model.brainPacks.value.filter(value => value !== pack)
                  }}
                />
              </label>
            ))}
          </div>
        )}
        {isPrivileged ? <p className="text-sm text-muted-foreground">{t('console.tenants.protected')}</p> : null}
        {selected?.suspended_at ? (
          <p className="text-sm text-muted-foreground">{t('console.tenants.suspended_hint')}</p>
        ) : null}
        {selected?.deleting_at ? (
          <p className="text-sm text-muted-foreground">{t('console.tenants.deleting_hint')}</p>
        ) : null}
      </fieldset>
    </ResourceEditorPage>
  )
}

function TransferAdministration({ tenant }: { tenant: Tenant }) {
  const { t } = useTranslation()
  const [principalUID, setPrincipalUID] = useState('')
  const principals = useQuery({
    ...listPrincipalsOptions({ headers: { 'x-ankole-tenant': tenant.id } }),
    select: data => fromDocument(data)
  })
  const humans = principals.data?.filter(principal => principal.type === 'human' && principal.status === 'active') ?? []
  const transfer = useMutation({
    meta: { invalidates: false },
    ...transferSiteAdministrationMutation(),
    onSuccess: () => {
      clearDataTenant()
      window.location.assign('/sessions/new')
    }
  })
  return (
    <section className="grid gap-4 border-t border-border pt-6">
      <h2 className="text-base font-semibold">{t('console.tenants.transfer')}</h2>
      <p className="text-sm text-muted-foreground">{t('console.tenants.transfer_description')}</p>
      <ErrorBlock error={principals.error ?? transfer.error} />
      <LabeledField label={t('console.tenants.new_site_admin')}>
        <SinglePrincipalPicker
          ariaLabel={t('console.tenants.new_site_admin')}
          candidates={humans.map(principal => ({
            id: principal.id,
            label: principalLabel(principal),
            description: principal.email ?? principal.handle
          }))}
          error={principals.error}
          isLoading={principals.isLoading}
          placeholder={t('console.tenants.choose_human')}
          value={principalUID}
          onChange={setPrincipalUID}
        />
      </LabeledField>
      {!principals.isLoading && !humans.length ? (
        <p className="text-sm text-muted-foreground">{t('console.tenants.no_humans')}</p>
      ) : null}
      {principalUID ? (
        <ConfirmDeleteButton
          label={t('console.tenants.transfer')}
          pending={transfer.isPending}
          confirm={{
            title: t('console.tenants.transfer'),
            description: t('console.tenants.transfer_confirm', { name: tenant.display_name }),
            confirmLabel: t('console.tenants.transfer')
          }}
          onConfirm={() =>
            transfer.mutate({
              body: {
                data: {
                  type: 'tenant',
                  id: tenant.id,
                  attributes: { tenant_id: tenant.id, site_admin_uid: principalUID }
                }
              }
            })
          }
        />
      ) : null}
    </section>
  )
}
