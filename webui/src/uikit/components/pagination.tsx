import { RiArrowLeftSLine, RiArrowRightSLine, RiMoreLine } from "@remixicon/react"
import type * as React from "react"
import { Button } from "@/uikit/components/button"
import { cn } from "@/uikit/lib/utils"

function Pagination({ className, ...props }: React.ComponentProps<"nav">) {
  return (
    <nav
      aria-label="pagination"
      data-slot="pagination"
      className={cn("mx-auto flex w-full justify-center", className)}
      {...props}
    />
  )
}

function PaginationContent({ className, ...props }: React.ComponentProps<"ul">) {
  return <ul data-slot="pagination-content" className={cn("flex items-center gap-0", className)} {...props} />
}

function PaginationItem({ ...props }: React.ComponentProps<"li">) {
  return <li data-slot="pagination-item" {...props} />
}

type PaginationLinkProps = {
  isActive?: boolean
} & Pick<React.ComponentProps<typeof Button>, "size"> &
  React.ComponentProps<"a">

function PaginationLink({ className, isActive, size = "icon", ...props }: PaginationLinkProps) {
  return (
    <Button
      variant="ghost"
      size={size}
      className={cn(
        "relative size-12! min-w-0! justify-center! p-0! text-foreground! hover:bg-muted! data-[active=true]:bg-transparent! data-[active=true]:font-semibold data-[active=true]:after:absolute data-[active=true]:after:bottom-0 data-[active=true]:after:left-1/2 data-[active=true]:after:h-1 data-[active=true]:after:w-4 data-[active=true]:after:-translate-x-1/2 data-[active=true]:after:bg-primary",
        className,
      )}
      nativeButton={false}
      render={
        <a aria-current={isActive ? "page" : undefined} data-slot="pagination-link" data-active={isActive} {...props} />
      }
    />
  )
}

function PaginationPrevious({
  className,
  text = "Previous",
  ...props
}: React.ComponentProps<typeof PaginationLink> & { text?: string }) {
  return (
    <PaginationLink aria-label="Go to previous page" size="icon" className={cn(className)} {...props}>
      <RiArrowLeftSLine data-icon="inline-start" />
      <span className="sr-only">{text}</span>
    </PaginationLink>
  )
}

function PaginationNext({
  className,
  text = "Next",
  ...props
}: React.ComponentProps<typeof PaginationLink> & { text?: string }) {
  return (
    <PaginationLink aria-label="Go to next page" size="icon" className={cn(className)} {...props}>
      <span className="sr-only">{text}</span>
      <RiArrowRightSLine data-icon="inline-end" />
    </PaginationLink>
  )
}

function PaginationEllipsis({ className, ...props }: React.ComponentProps<"span">) {
  return (
    <span
      aria-hidden
      data-slot="pagination-ellipsis"
      className={cn(
        "flex size-12 items-center justify-center text-muted-foreground [&_svg:not([class*='size-'])]:size-4",
        className,
      )}
      {...props}>
      <RiMoreLine />
      <span className="sr-only">More pages</span>
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
  PaginationPrevious,
}
