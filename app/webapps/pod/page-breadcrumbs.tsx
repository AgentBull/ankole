import { usePagesMetadata } from './use-page-metadata'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@ankole/uikit'
import { RiArrowRightSLine, RiMoreFill } from '@remixicon/react'
import { Link } from '@tanstack/react-router'

import { podLocation } from '../common/browser-context'
import { BdiLabel } from '../common/bidi-file-name'
import { stripBidi } from '../common/bidi'
import { linkTarget } from '../common/router'
import { pageLocation } from './state/page-location'
import type { Page } from './content-api'

// The path speaks in value alone: ancestors are secondary ink and wash on hover, the open Page is full ink at
// medium weight, and every item keeps the header's one text size.
const crumb =
  'inline-flex h-7 max-w-45 min-w-0 items-center rounded-control px-1.5 text-sm text-fg-secondary no-underline hover:bg-accent hover:text-foreground data-popup-open:bg-accent data-popup-open:text-foreground max-md:max-w-25'
const separator = <RiArrowRightSLine aria-hidden className="size-4 shrink-0 text-fg-tertiary" />

/**
 * The header path, in text only. Every Page header starts from the same anchor, `Pages`, so the band keeps
 * one shape from Page to Page; the direct parent follows, and any ancestors between them fold into a menu.
 * On a phone the anchor gives way to the title and every ancestor folds into the menu. Ancestors shrink
 * before the title does.
 */
export function PageBreadcrumbs({
  ancestors: sourceAncestors,
  title,
  compact,
  current
}: {
  /** The readable ancestors from the root down to the parent, as the Page read returns them. */
  ancestors: readonly Page[]
  title: string
  compact: boolean
  /** Replaces the open Page's title, such as with a field that renames it in place. */
  current?: ReactNode
}) {
  const { t } = useTranslation()
  const brain = sourceAncestors.some(page => page.type === 'knowledge' || page.system_key?.startsWith('ankole_brain'))
  const ancestors = usePagesMetadata(sourceAncestors).filter(page => page.system_key !== 'ankole_brain')
  const folded = compact ? ancestors : ancestors.slice(0, -1)
  const parent = compact ? undefined : ancestors.at(-1)
  return (
    <nav className="pod-page-breadcrumbs min-w-0" aria-label={t('pod.content.page_path')}>
      <ol className="flex min-w-0 items-center">
        {!compact && (
          <li className="flex shrink-0 items-center">
            <Link className={crumb} to={brain ? '/meta/brain' : podLocation('/content/all').pathname}>
              {t(brain ? 'pod.meta.brain' : 'pod.content.pages')}
            </Link>
            {separator}
          </li>
        )}
        {folded.length > 0 && (
          <li className="flex shrink-0 items-center">
            <DropdownMenu>
              <DropdownMenuTrigger
                aria-label={t('pod.content.hidden_ancestor_pages')}
                title={t('pod.content.hidden_ancestor_pages')}
                className={crumb}>
                <RiMoreFill aria-hidden className="size-4" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="min-w-48">
                {folded.map(ancestor => (
                  <DropdownMenuItem
                    key={ancestor.id}
                    render={<Link {...linkTarget(pageLocation(ancestor, sourceAncestors))} />}>
                    <BdiLabel value={ancestor.title} fallback={t('pod.content.untitled')} />
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
            {separator}
          </li>
        )}
        {parent && (
          <li className="flex min-w-0 shrink-[4] items-center">
            <Link
              className={crumb}
              {...linkTarget(pageLocation(parent, sourceAncestors))}
              title={stripBidi(parent.title)}>
              <BdiLabel value={parent.title} fallback={t('pod.content.untitled')} />
            </Link>
            {separator}
          </li>
        )}
        <li
          aria-current="page"
          className="flex min-w-0 items-center px-1.5 text-sm font-medium text-foreground"
          title={current ? undefined : stripBidi(title)}>
          {current ?? <BdiLabel value={title} fallback={t('pod.content.untitled')} />}
        </li>
      </ol>
    </nav>
  )
}
