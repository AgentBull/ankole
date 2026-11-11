import { usePagesMetadata } from './use-page-metadata'
import { Fragment, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import {
  Breadcrumb,
  BreadcrumbEllipsis,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@ankole/uikit'
import { Link } from '@tanstack/react-router'

import { podLocation } from '../common/browser-context'
import { BdiLabel } from '../common/bidi-file-name'
import { stripBidi } from '../common/bidi'
import { linkTarget } from '../common/router'
import { pageLocation } from './state/page-location'
import type { Page } from './content-api'

/**
 * The Page's path in the top bar, in text only. Every path starts from the same anchor, `Pages`, so the bar keeps
 * one shape from Page to Page; the direct parent follows, and any ancestors between them fold into a menu behind
 * the ellipsis. On a phone the anchor gives way to the title and every ancestor folds into the menu. Ancestors
 * shrink before the title does.
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
  const crumbs = [
    !compact && (
      <BreadcrumbItem key="anchor" className="shrink-0">
        <BreadcrumbLink render={<Link to={brain ? '/meta/brain' : podLocation('/content/all').pathname} />}>
          <span>{t(brain ? 'pod.meta.brain' : 'pod.content.pages')}</span>
        </BreadcrumbLink>
      </BreadcrumbItem>
    ),
    folded.length > 0 && (
      <BreadcrumbItem key="folded" className="shrink-0">
        <DropdownMenu>
          <BreadcrumbEllipsis
            label={t('pod.content.hidden_ancestor_pages')}
            title={t('pod.content.hidden_ancestor_pages')}
            render={<DropdownMenuTrigger />}
          />
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
      </BreadcrumbItem>
    ),
    parent && (
      <BreadcrumbItem key="parent" className="max-w-45 shrink-[4] max-md:max-w-25">
        <BreadcrumbLink
          render={<Link {...linkTarget(pageLocation(parent, sourceAncestors))} />}
          title={stripBidi(parent.title)}>
          <span>
            <BdiLabel value={parent.title} fallback={t('pod.content.untitled')} />
          </span>
        </BreadcrumbLink>
      </BreadcrumbItem>
    ),
    <BreadcrumbItem key="current" className="min-w-0">
      <BreadcrumbPage title={current ? undefined : stripBidi(title)}>
        {current ? (
          // A field keeps its focus ring, so it sits outside the truncating label span.
          <div className="flex min-w-0">{current}</div>
        ) : (
          <span>
            <BdiLabel value={title} fallback={t('pod.content.untitled')} />
          </span>
        )}
      </BreadcrumbPage>
    </BreadcrumbItem>
  ].filter(Boolean)
  return (
    <Breadcrumb className="pod-page-breadcrumbs min-w-0" aria-label={t('pod.content.page_path')}>
      <BreadcrumbList>
        {crumbs.map((crumb, index) => (
          <Fragment key={index}>
            {index > 0 && <BreadcrumbSeparator />}
            {crumb}
          </Fragment>
        ))}
      </BreadcrumbList>
    </Breadcrumb>
  )
}
