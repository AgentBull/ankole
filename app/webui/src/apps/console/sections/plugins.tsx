import { useTranslation } from 'react-i18next'
import { TableCell, TableRow } from '@/uikit/components/table'
import { useAdaptersQuery } from '../helpers'
import { SectionHeader, TableCard } from '../shared'

/** Lists discovered external-gateway adapters and whether they support interactive setup. */
export function PluginsPage() {
  const { t } = useTranslation()
  const adapters = useAdaptersQuery()
  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.plugins.title')} description={t('console.plugins.description')} />
      <TableCard
        loading={adapters.isPending}
        error={adapters.error}
        empty={(adapters.data?.adapters.length ?? 0) === 0}
        columns={[
          t('console.plugins.column_adapter'),
          t('console.plugins.column_plugin'),
          t('console.plugins.column_interactive')
        ]}>
        {(adapters.data?.adapters ?? []).map(adapter => (
          <TableRow key={adapter.id}>
            <TableCell className="font-mono text-xs">{adapter.id}</TableCell>
            <TableCell>{adapter.pluginId}</TableCell>
            <TableCell>{adapter.interactiveConfig ? t('console.yes') : t('console.no')}</TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}
