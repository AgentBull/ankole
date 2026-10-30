import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Button, Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { contentError } from './content-errors'
import { ErrorBlock } from '../common/error-block'
import type { PageRole, PageScope, PageType } from './content-api'
import { RiDeleteBinLine, RiFolderLine, RiHistoryLine, RiLockLine, RiShareLine, RiStarLine } from '@remixicon/react'

export const scopeLabels: Record<PageScope, string> = {
  get all() {
    return t('pod.content.all_pages')
  },
  get space() {
    return t('pod.content.space')
  },
  get private() {
    return t('pod.content.private')
  },
  get shared() {
    return t('pod.content.shared_with_me')
  },
  get recent() {
    return t('pod.content.recently_visited')
  },
  get favorites() {
    return t('pod.content.favorites')
  },
  get trash() {
    return t('pod.content.trash')
  }
}

export const scopeIcons = {
  all: RiFolderLine,
  space: RiFolderLine,
  private: RiLockLine,
  shared: RiShareLine,
  recent: RiHistoryLine,
  favorites: RiStarLine,
  trash: RiDeleteBinLine
}

export const typeLabels: Record<PageType, string> = {
  get doc() {
    return t('pod.content.document')
  },
  get base() {
    return t('pod.editor.base')
  },
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
  get contribute() {
    return t('pod.document.can_contribute')
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
  onChange(value: NoInfer<T>): void
  options: Partial<Record<NoInfer<T>, string>>
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
        {Object.entries<string | undefined>(options).map(([key, text]) => (
          <SelectItem key={key} value={key}>
            {text}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

export function ContentError({ error, retry }: { error: unknown; retry?: () => void }) {
  const { t } = useTranslation()
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
  variant?: 'default' | 'overlay'
}) {
  return (
    <label className="grid gap-1.5 text-sm">
      <span>{label}</span>
      <Input {...props} value={value} onChange={event => onChange(event.target.value)} />
    </label>
  )
}
