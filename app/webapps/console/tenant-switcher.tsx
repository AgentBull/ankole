import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebTenantControllerIndexOptions,
  ankoleWebTenantControllerPrivilegedOptions
} from './api/generated/@tanstack/react-query.gen'
import { dataTenantID, selectDataTenant } from '../common/browser-session'

export function TenantSwitcher() {
  const { t } = useTranslation()
  const tenants = useQuery(ankoleWebTenantControllerIndexOptions())
  const privileged = useQuery(ankoleWebTenantControllerPrivilegedOptions())
  const items = tenants.data?.tenants.filter(tenant => !tenant.deleting_at) ?? []
  if (items.length < 2) return null
  return (
    <Select value={dataTenantID() ?? privileged.data?.tenant.id ?? ''} onValueChange={selectDataTenant}>
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
