import { Button } from '@ankole/uikit'
import { RiResetLeftLine } from '@remixicon/react'
import { type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import type { AppConfigurationItem } from '../api/generated/types.gen'

/** One labeled section of a specialized settings-group editor, with its restore-default action. */
export function SettingGroupField({
  children,
  description,
  item,
  label,
  onRestore,
  saving
}: {
  children: ReactNode
  description: string
  item?: AppConfigurationItem
  label: string
  onRestore: (item: AppConfigurationItem) => void
  saving: boolean
}) {
  const { t } = useTranslation()

  return (
    <section className="grid gap-3 border-t border-border pt-6 first:border-t-0 first:pt-0">
      <div className="flex items-start justify-between gap-3">
        <div className="grid min-w-0 gap-1">
          <h2 className="text-sm font-semibold text-foreground">{label}</h2>
          <p className="text-xs leading-5 text-muted-foreground">{description}</p>
        </div>
        {item?.overridden ? (
          <Button disabled={saving} size="sm" type="button" variant="ghost" onClick={() => onRestore(item)}>
            <RiResetLeftLine />
            {t('console.settings.restore_default')}
          </Button>
        ) : null}
      </div>
      {children}
    </section>
  )
}
