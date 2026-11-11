import { ChevronLeftRegular, ChevronRightRegular, MoreHorizontalRegular } from '../icons'
import type * as React from 'react'
import { Button } from './button'
import { cn } from '../lib/utils'

function Pagination({ className, ...props }: React.ComponentProps<'nav'>) {
  return (
    <nav
      aria-label="pagination"
      data-slot="pagination"
      className={cn('mx-auto flex w-full justify-center', className)}
      {...props}
    />
  )
}

function PaginationContent({ className, ...props }: React.ComponentProps<'ul'>) {
  return <ul data-slot="pagination-content" className={cn('flex items-center gap-0', className)} {...props} />
}

function PaginationItem({ ...props }: React.ComponentProps<'li'>) {
  return <li data-slot="pagination-item" {...props} />
}

type PaginationLinkProps = {
  isActive?: boolean
} & Pick<React.ComponentProps<typeof Button>, 'size'> &
  React.ComponentProps<'a'>

function PaginationLink({ className, isActive, size = 'icon', ...props }: PaginationLinkProps) {
  return (
    <Button
      variant="ghost"
      size={size}
      className={cn(
        'relative size-8! min-w-0! justify-center! p-0! text-foreground! hover:bg-accent! data-[active=true]:bg-transparent! data-[active=true]:font-semibold data-[active=true]:after:absolute data-[active=true]:after:inset-x-2 data-[active=true]:after:bottom-0 data-[active=true]:after:h-0.5 data-[active=true]:after:bg-foreground',
        className
      )}
      nativeButton={false}
      render={
        <a aria-current={isActive ? 'page' : undefined} data-slot="pagination-link" data-active={isActive} {...props} />
      }
    />
  )
}

function PaginationPrevious({
  className,
  label,
  text = 'Previous',
  ...props
}: React.ComponentProps<typeof PaginationLink> & { label?: string; text?: string }) {
  return (
    <PaginationLink
      aria-label={label ?? (text === 'Previous' ? 'Go to previous page' : text)}
      size="icon"
      className={cn(className)}
      {...props}>
      <ChevronLeftRegular aria-hidden="true" data-icon="inline-start" />
      <span className="sr-only">{text}</span>
    </PaginationLink>
  )
}

function PaginationNext({
  className,
  label,
  text = 'Next',
  ...props
}: React.ComponentProps<typeof PaginationLink> & { label?: string; text?: string }) {
  return (
    <PaginationLink
      aria-label={label ?? (text === 'Next' ? 'Go to next page' : text)}
      size="icon"
      className={cn(className)}
      {...props}>
      <span className="sr-only">{text}</span>
      <ChevronRightRegular aria-hidden="true" data-icon="inline-end" />
    </PaginationLink>
  )
}

function PaginationEllipsis({ className, label, ...props }: React.ComponentProps<'span'> & { label?: string }) {
  const hidden = props['aria-hidden'] ?? true
  return (
    <span
      aria-hidden={hidden}
      data-slot="pagination-ellipsis"
      className={cn(
        "flex size-8 items-center justify-center text-muted-foreground [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}>
      <MoreHorizontalRegular aria-hidden="true" />
      {!hidden && label ? <span className="sr-only">{label}</span> : null}
    </span>
  )
}

export {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious
}
