import { buttonVariants, cn } from '@ankole/uikit'
import { useQuery as useBaseQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { getPrivilegedTenantOptions, listTenantsOptions } from './api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from './api/json-api'
import { useConsoleTenant, useEffectiveDataTenantID } from './tenant-context'
import type { PodSettingsSection } from '../pod/slots'

export type { PodSettingsSection }

export function PodSettingsLinkBanner({ section }: { section: PodSettingsSection }) {
  const { t } = useTranslation()
  const contextTenant = useConsoleTenant()
  const effectiveTenantID = useEffectiveDataTenantID(!contextTenant)
  const tenants = useBaseQuery({ ...listTenantsOptions(), select: document => fromDocument(document) })
  const privileged = useBaseQuery({
    ...getPrivilegedTenantOptions(),
    select: document => fromDocument(document),
    enabled: !contextTenant && !effectiveTenantID
  })
  const targetID = contextTenant?.id ?? effectiveTenantID ?? privileged.data?.id
  const activeTenant = tenants.data?.find(item => item.id === targetID)
  const href = activeTenant?.pod_origin
    ? `${activeTenant.pod_origin.replace(/\/+$/, '')}/settings?section=${encodeURIComponent(section)}`
    : undefined

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border border-border-subtle bg-layer-03/30 px-4 py-3 text-sm">
      <p className="text-fg-secondary">{t('console.human_access.pod_settings_owner_hint')}</p>
      {href ? (
        <a
          href={href}
          target="_blank"
          rel="noreferrer"
          className={cn(buttonVariants({ size: 'sm', variant: 'outline' }), 'shrink-0')}>
          {t('console.human_access.open_pod_settings')}
        </a>
      ) : null}
    </div>
  )
}
