import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { getPrivilegedTenantOptions, listTenantsOptions } from './api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from './api/json-api'
import { dataTenantID, selectDataTenant } from '../common/browser-session'

export function TenantSwitcher() {
  const { t } = useTranslation()
  const tenants = useQuery({ ...listTenantsOptions(), select: document => fromDocument(document) })
  const privileged = useQuery({ ...getPrivilegedTenantOptions(), select: document => fromDocument(document) })
  const items = tenants.data?.filter(tenant => !tenant.deleting_at) ?? []
  if (items.length < 2) return null
  return (
    <Select value={dataTenantID() ?? privileged.data?.id ?? ''} onValueChange={selectDataTenant}>
      <SelectTrigger aria-label={t('console.tenants.data_context')} className="max-w-52">
        <SelectValue placeholder={t('console.tenants.data_context')} />
      </SelectTrigger>
      <SelectContent>
        {items.map(tenant => (
          <SelectItem key={tenant.id} value={tenant.id}>
            {tenant.display_name}
            {tenant.suspended_at ? ` (${t('console.tenants.suspended')})` : ''}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
