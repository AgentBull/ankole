import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useLocation, useMatches, useRouter, type AnyRouter } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { listTenantsOptions } from './api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from './api/json-api'
import { ErrorBlock } from '../common/error-block'
import { ErrorBoundary } from '../common/error-boundary'
import { hasSiteAggregateView, SiteAggregateView } from './site-aggregates'
import { consoleSlotPageKind, type ConsoleRouteSlot } from './slots'
import { ConsoleBoundTenantIDContext, ConsoleTenantContext, useEffectiveDataTenantID } from './tenant-context'
import { consoleTenantPage, tenantSwitchPath } from './state/tenant-scope'

const ALL_TENANTS = '__all__'

function useTenants(enabled = true) {
  return useQuery({ ...listTenantsOptions(), select: document => fromDocument(document), enabled })
}

export function TenantSwitcher({ record = false, search = {} }: { record?: boolean; search?: Record<string, string> }) {
  const { t } = useTranslation()
  const tenants = useTenants()
  const location = useLocation()
  const router: AnyRouter = useRouter()
  const selected = useEffectiveDataTenantID(true)
  const items = tenants.data?.filter(tenant => !tenant.deleting_at) ?? []
  const explicitAll = new URLSearchParams(location.searchStr).get('data_tenant') === ''
  if (tenants.isSuccess && items.length === 1 && !explicitAll) return null

  const tenantLabel = (tenant: (typeof items)[number]) =>
    `${tenant.display_name} (${tenant.slug})${tenant.suspended_at ? ` (${t('console.tenants.suspended')})` : ''}`
  return (
    <div className="grid min-w-0 gap-3">
      <div className="flex min-w-0 flex-wrap items-center gap-3">
        <span className="text-sm font-medium">{t('console.tenants.tenant')}</span>
        <Select
          loading={tenants.isPending}
          value={selected ?? (record ? '' : ALL_TENANTS)}
          onValueChange={value => {
            const nextTenant = value === ALL_TENANTS ? null : value
            const path = record ? tenantSwitchPath(location.pathname, Boolean(selected)) : location.pathname
            void router.navigate({
              to: path,
              search: { ...search, data_tenant: nextTenant ?? '' }
            })
          }}>
          <SelectTrigger aria-label={t('console.tenants.data_context')} className="w-full sm:w-80">
            <SelectValue placeholder={t('console.tenants.choose')} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={ALL_TENANTS}>{t('console.tenants.all')}</SelectItem>
            {items.map(tenant => (
              <SelectItem key={tenant.id} value={tenant.id}>
                {tenantLabel(tenant)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <ErrorBlock error={tenants.error} />
    </div>
  )
}

/** Single-tenant sites bind automatically; multi-tenant sites use cursor-paginated site aggregates where available. */
export function ConsoleTenantContent({ children, slot }: { children: ReactNode; slot?: ConsoleRouteSlot }) {
  const { t } = useTranslation()
  const location = useLocation()
  const fallback = useMatches({ select: matches => matches.at(-1)?.fullPath === '/$' })
  const selfManaged = location.pathname === '/model-profiles'
  const mode =
    fallback || selfManaged
      ? 'site'
      : slot
        ? slot.scope === 'site'
          ? 'site'
          : consoleSlotPageKind(slot)
        : consoleTenantPage(location.pathname, new URLSearchParams(location.searchStr))
  const tenants = useTenants(mode !== 'site')
  const selected = useEffectiveDataTenantID(mode !== 'site')
  if (mode === 'site') return children
  const items = tenants.data?.filter(tenant => !tenant.deleting_at) ?? []
  const renderContent = (): ReactNode => {
    if (selected) {
      return (
        <ConsoleBoundTenantIDContext key={selected} value={selected}>
          {children}
        </ConsoleBoundTenantIDContext>
      )
    }
    if (mode === 'record') {
      return tenants.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : (
        <p role="status" className="text-sm text-fg-secondary">
          {t('console.tenants.choose_for_record')}
        </p>
      )
    }
    if (hasSiteAggregateView(location.pathname)) {
      return <SiteAggregateView pathname={location.pathname} />
    }
    if (tenants.isPending) {
      return <p role="status">{t('common.loading')}</p>
    }
    return items.map((tenant, index) => {
      const tenantLabel = `${tenant.display_name} (${tenant.slug})`
      return (
        <ConsoleTenantContext key={tenant.id} value={{ ...tenant, first: index === 0 }}>
          <section aria-label={tenantLabel} className="min-w-0">
            <ErrorBoundary
              variant="panel"
              label={tenantLabel}
              resetKeys={[tenant.id, location.pathname, location.searchStr]}>
              {children}
            </ErrorBoundary>
          </section>
        </ConsoleTenantContext>
      )
    })
  }

  return (
    <div className="grid min-w-0 gap-6">
      <TenantSwitcher record={mode === 'record'} />
      {renderContent()}
    </div>
  )
}
