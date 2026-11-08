import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import {
  Button,
  cn,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Spinner
} from '@ankole/uikit'
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
  get knowledge() {
    return t('pod.knowledge.page')
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

type LoadingProps = {
  label?: string
  className?: string
  immediate?: boolean
}

/*
 * The Pod picks a loading status by what the reader is waiting for. A region whose shape is known, such as a
 * page, a list, or a table, shows a ContentSkeleton of that shape. A region whose content has no predictable
 * shape, such as an applet or a file preview, shows a centered ContentLoading spinner. A picker, a menu, or a
 * single line shows an InlineLoading spinner next to its text. A button busy with its own action shows a UIKit
 * Spinner in place of its icon.
 *
 * Every status fades in after a short delay, so a load that finishes sooner never flashes it. A caller whose
 * status directly follows an earlier one passes `immediate`, which shows it at once so the indicator does
 * not disappear and come back. Callers place each status in their own layout through `className`.
 */

/** A centered spinner and label for a region whose content has no predictable shape. */
export function ContentLoading({ label, className, immediate = false }: LoadingProps) {
  const { t } = useTranslation()
  return (
    <p
      role="status"
      data-immediate={immediate || undefined}
      className={cn('pod-loading flex min-h-32 items-center justify-center gap-2 text-sm', className)}>
      <Spinner aria-hidden className="pod-chat-working-spinner" data-size="lg" />
      <span className="pod-chat-working-label">{label ?? t('pod.content.loading')}</span>
    </p>
  )
}

const textSkeletonLines = ['w-full', 'w-11/12', 'w-4/5', 'w-full', 'w-3/5']

/**
 * Gray placeholders in the shape of the content that is loading: a `page` with its title, the `text` of a body
 * whose title is already shown, a `list`, a `table`, or a `block` that fills the height its caller gives it.
 * Screen readers hear the label, because the placeholders themselves carry no meaning.
 */
export function ContentSkeleton({
  variant,
  rows,
  label,
  className,
  immediate = false
}: LoadingProps & { variant: 'page' | 'text' | 'list' | 'table' | 'block'; rows?: number }) {
  const { t } = useTranslation()
  const count = rows ?? (variant === 'table' ? 6 : 4)
  return (
    <div
      role="status"
      data-immediate={immediate || undefined}
      className={cn(
        'pod-loading grid content-start gap-2',
        variant === 'page' && 'mx-auto w-full max-w-[856px] gap-3 px-6 py-7 md:px-16 md:py-10',
        variant === 'block' && 'flex h-48',
        className
      )}>
      <span className="sr-only">{label ?? t('pod.content.loading')}</span>
      {variant === 'page' && <Skeleton className="mb-5 h-10 w-2/5" />}
      {(variant === 'page' || variant === 'text') &&
        textSkeletonLines.map((width, index) => <Skeleton key={index} className={cn('h-4', width)} />)}
      {variant === 'list' && Array.from({ length: count }, (_, index) => <Skeleton key={index} className="h-8" />)}
      {variant === 'table' && (
        <>
          <Skeleton className="h-9" />
          {Array.from({ length: count }, (_, index) => (
            <Skeleton key={index} className="h-7" />
          ))}
        </>
      )}
      {variant === 'block' && <Skeleton className="w-full" />}
    </div>
  )
}

/** A small spinner beside its label, for a picker, a menu, a form field, or a single line of text. */
export function InlineLoading({ label, className, immediate = false }: LoadingProps) {
  const { t } = useTranslation()
  return (
    <span
      role="status"
      data-immediate={immediate || undefined}
      className={cn('pod-loading inline-flex items-center gap-1.5 text-sm text-fg-tertiary', className)}>
      <Spinner aria-hidden className="pod-chat-working-spinner" />
      {label ?? t('pod.content.loading')}
    </span>
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
