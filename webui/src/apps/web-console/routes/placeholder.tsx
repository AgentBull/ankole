import { RiArrowGoBackLine, RiCompassLine } from "@remixicon/react"
import { Link, useParams } from "@tanstack/react-router"
import { Button } from "@/uikit/components/button"
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/uikit/components/empty"
import { findNavItem, humanizeSlug } from "../components/nav"

export function SectionPlaceholder() {
  const { section } = useParams({ from: "/$section" })
  const item = findNavItem(section)
  const title = item?.title ?? humanizeSlug(section)
  const Icon = item?.icon ?? RiCompassLine

  return (
    <Empty className="flex-1 border border-dashed border-border">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <Icon className="size-5" />
        </EmptyMedia>
        <EmptyTitle>{title}</EmptyTitle>
        <EmptyDescription>
          {item?.description ?? "This area is part of the console scaffold."} It isn’t wired up yet — the page and its
          API will land here.
        </EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button variant="outline" size="sm" render={<Link to="/" />}>
          <RiArrowGoBackLine />
          Back to overview
        </Button>
      </EmptyContent>
    </Empty>
  )
}

export function NotFound() {
  return (
    <Empty className="flex-1 border border-dashed border-border">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <RiCompassLine className="size-5" />
        </EmptyMedia>
        <EmptyTitle>Page not found</EmptyTitle>
        <EmptyDescription>The console route you followed doesn’t exist.</EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button variant="outline" size="sm" render={<Link to="/" />}>
          <RiArrowGoBackLine />
          Back to overview
        </Button>
      </EmptyContent>
    </Empty>
  )
}
