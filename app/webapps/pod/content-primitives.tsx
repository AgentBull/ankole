import { t } from 'i18next'
import { Button, Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import type { ReactNode } from 'react'
import { Link } from 'react-router'
import { podLocation } from '../common/browser-context'
import { contentError } from './content-errors'
import { ErrorBlock } from '../common/error-block'
import { PageIcon } from './page-icon'
import type { Page, PageRole, PageType } from './content-api'

export const typeLabels: Record<PageType, string> = {
  get doc() {
    return t('pod.content.document')
  },
  database: 'Database',
  get applet() {
    return t('pod.content.applet')
  },
  get file() {
    return t('pod.content.file')
  }
}
export const roleLabels: Record<PageRole, string> = {
  get view() {
    return t('pod.content.can_view')
  },
  get edit() {
    return t('pod.content.can_edit')
  },
  get manage() {
    return t('pod.content.full_access')
  }
}

export function Choice<T extends string>({
  value,
  onChange,
  options,
  label,
  disabled
}: {
  value: T
  onChange(value: T): void
  options: Record<T, string>
  label: string
  disabled?: boolean
}) {
  return (
    <Select
      value={value}
      onValueChange={next => {
        if (next !== null) onChange(next)
      }}
      disabled={disabled}>
      <SelectTrigger aria-label={label}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {Object.entries<string>(options).map(([key, text]) => (
          <SelectItem key={key} value={key}>
            {text}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

export function PageLink({ page, children }: { page: Page; children?: ReactNode }) {
  return (
    <Link className="link inline-flex min-w-0 items-center gap-2" to={podLocation(`/pages/${page.id}`)}>
      <PageIcon page={page} />
      <span className="truncate">{children ?? (page.title || t('pod.content.untitled'))}</span>
    </Link>
  )
}

export function ContentError({ error, retry }: { error: unknown; retry?: () => void }) {
  return (
    <ErrorBlock
      error={contentError(error)}
      action={
        retry ? (
          <Button variant="outline" size="sm" onClick={retry}>
            {t('pod.content.retry')}
          </Button>
        ) : undefined
      }
    />
  )
}

export function TextField({
  label,
  value,
  onChange,
  ...props
}: {
  label: string
  value: string
  onChange(value: string): void
  placeholder?: string
  disabled?: boolean
}) {
  return (
    <label className="grid gap-1.5 text-sm">
      <span>{label}</span>
      <Input {...props} value={value} onChange={event => onChange(event.target.value)} />
    </label>
  )
}
