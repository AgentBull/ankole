import { RiApps2Line, RiAttachment2, RiDatabase2Line, RiFileTextLine } from '@remixicon/react'
import { cn } from '@ankole/uikit'
import type { Page } from './content-api'

const icons = { doc: RiFileTextLine, database: RiDatabase2Line, applet: RiApps2Line, file: RiAttachment2 }

/** A Page keeps the same type mark in navigation, references, and pickers. */
export function PageIcon({ page, className }: { page: Pick<Page, 'type' | 'icon'>; className?: string }) {
  const classes = cn('pod-page-icon', className)
  if (page.icon) {
    return (
      <span aria-hidden className={classes}>
        {page.icon}
      </span>
    )
  }
  const Icon = icons[page.type]
  return <Icon aria-hidden className={classes} />
}
