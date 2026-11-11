import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import type * as React from 'react'
import { cn } from '../lib/utils'

/**
 * The path to the open place, as a navigation landmark that the caller names. Crumbs are 12px secondary text on a
 * 20px line, 4px apart; a crumb may lead with a 20px icon or emoji, and its label truncates when the path runs
 * out of room.
 */
function Breadcrumb(props: React.ComponentProps<'nav'> & { 'aria-label': string }) {
  return <nav data-slot="breadcrumb" {...props} />
}

function BreadcrumbList({ className, ...props }: React.ComponentProps<'ol'>) {
  return (
    <ol
      data-slot="breadcrumb-list"
      className={cn('flex min-w-0 items-center gap-1 text-50 whitespace-nowrap text-fg-secondary', className)}
      {...props}
    />
  )
}

function BreadcrumbItem({ className, ...props }: React.ComponentProps<'li'>) {
  return (
    <li data-slot="breadcrumb-item" className={cn('inline-flex min-w-0 items-center gap-1', className)} {...props} />
  )
}

const crumbClassName =
  "inline-flex min-w-0 items-center gap-1 [&>span]:truncate [&>svg]:shrink-0 [&>svg:not([class*='size-'])]:size-5"

/**
 * A crumb that leads to an earlier place: a link by default, or the element that `render` names, such as a router
 * link. Wrap the label in a `span` so it truncates beside its icon.
 */
function BreadcrumbLink({ className, render, ...props }: useRender.ComponentProps<'a'> & React.ComponentProps<'a'>) {
  return useRender({
    defaultTagName: 'a',
    props: mergeProps<'a'>(
      {
        className: cn(
          crumbClassName,
          'rounded-mini text-fg-secondary no-underline transition-colors duration-(--duration-feedback) ease-productive hover:text-foreground',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'breadcrumb-link'
    }
  })
}

/** The open place, the last crumb. It reads like the other crumbs and is not a link. */
function BreadcrumbPage({ className, ...props }: React.ComponentProps<'span'>) {
  return <span data-slot="breadcrumb-page" aria-current="page" className={cn(crumbClassName, className)} {...props} />
}

/** The tertiary slash between two crumbs. `children` replaces the slash. */
function BreadcrumbSeparator({ children, className, ...props }: React.ComponentProps<'li'>) {
  return (
    <li
      data-slot="breadcrumb-separator"
      role="presentation"
      aria-hidden="true"
      className={cn('shrink-0 text-fg-tertiary', className)}
      {...props}>
      {children ?? '/'}
    </li>
  )
}

/**
 * The crumbs that a long path folds away, drawn as "..." in 14px secondary text. `label` names them for assistive
 * technology; `render` turns the ellipsis into a menu trigger that lists the folded crumbs.
 */
function BreadcrumbEllipsis({
  className,
  render,
  label,
  ...props
}: useRender.ComponentProps<'span'> & Omit<React.ComponentProps<'span'>, 'children'> & { label?: string }) {
  return useRender({
    defaultTagName: 'span',
    props: mergeProps<'span'>(
      {
        className: cn(
          'inline-flex shrink-0 items-center rounded-mini text-75 text-fg-secondary transition-colors duration-(--duration-feedback) ease-productive [&:is(a,button)]:cursor-pointer [&:is(a,button)]:hover:text-foreground',
          className
        ),
        children: (
          <>
            <span aria-hidden>...</span>
            {label ? <span className="sr-only">{label}</span> : null}
          </>
        )
      },
      props
    ),
    render,
    state: {
      slot: 'breadcrumb-ellipsis'
    }
  })
}

export {
  Breadcrumb,
  BreadcrumbEllipsis,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator
}
