import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useLocation, useMatches, useRouter } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { listTenantsOptions } from './api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from './api/json-api'
import { dataTenantID, selectDataTenant } from '../common/browser-session'
import { ErrorBlock } from '../common/error-block'
import { ErrorBoundary } from '../common/error-boundary'
import type { ConsoleRouteSlot } from './slots'
import { ConsoleTenantContext } from './tenant-context'
import { consoleTenantPage, tenantSwitchPath } from './state/tenant-scope'

const ALL_TENANTS = '__all__'

function useTenants(enabled = true) {
  return useQuery({ ...listTenantsOptions(), select: document => fromDocument(document), enabled })
}

export function TenantSwitcher({ record = false, search = {} }: { record?: boolean; search?: Record<string, string> }) {
  const { t } = useTranslation()
  const tenants = useTenants()
  const location = useLocation()
  const router = useRouter()
  const items = tenants.data?.filter(tenant => !tenant.deleting_at) ?? []
  return (
    <div className="grid min-w-0 gap-3">
      <div className="flex min-w-0 flex-wrap items-center gap-3">
        <span className="text-sm font-medium">{t('console.tenants.tenant')}</span>
        <Select
          value={dataTenantID() ?? (record ? '' : ALL_TENANTS)}
          onValueChange={value => {
            const path = record ? tenantSwitchPath(location.pathname, Boolean(dataTenantID())) : location.pathname
            selectDataTenant(value === ALL_TENANTS ? null : value, router.buildLocation({ to: path, search }).href)
          }}>
          <SelectTrigger aria-label={t('console.tenants.data_context')} className="w-full sm:w-80">
            <SelectValue placeholder={t('console.tenants.choose')} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={ALL_TENANTS}>{t('console.tenants.all')}</SelectItem>
            {items.map(tenant => (
              <SelectItem key={tenant.id} value={tenant.id}>
                {tenant.display_name} ({tenant.slug}){tenant.suspended_at ? ` (${t('console.tenants.suspended')})` : ''}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <ErrorBlock error={tenants.error} />
    </div>
  )
}

/** Aggregate reads retain each tenant's API, filters, pagination, and mutation targets. */
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
          : /\$|\/new$/.test(slot.path)
            ? 'record'
            : 'collection'
        : consoleTenantPage(location.pathname, new URLSearchParams(location.searchStr))
  const tenants = useTenants(mode !== 'site')
  if (mode === 'site') return children
  const selected = dataTenantID()
  const items = tenants.data?.filter(tenant => !tenant.deleting_at) ?? []
  return (
    <div className="grid min-w-0 gap-6">
      <TenantSwitcher record={mode === 'record'} />
      {selected ? (
        children
      ) : mode === 'record' ? (
        <p role="status" className="text-sm text-muted-foreground">
          {t('console.tenants.choose_for_record')}
        </p>
      ) : tenants.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : (
        items.map((tenant, index) => {
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
      )}
    </div>
  )
}
