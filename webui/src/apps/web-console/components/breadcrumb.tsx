import { RiArrowRightSLine } from "@remixicon/react"
import { cn } from "@/uikit/lib/utils"

// The uikit has no breadcrumb primitive, so the console ships a minimal one.
export function Breadcrumb({ items }: { items: string[] }) {
  return (
    <nav aria-label="Breadcrumb" className="flex min-w-0 items-center gap-1.5 text-sm">
      {items.map((label, index) => {
        const isLast = index === items.length - 1
        return (
          <span key={`${label}-${index}`} className="flex min-w-0 items-center gap-1.5">
            {index > 0 ? <RiArrowRightSLine className="size-4 shrink-0 text-muted-foreground" /> : null}
            <span className={cn("truncate", isLast ? "font-medium text-foreground" : "text-muted-foreground")}>
              {label}
            </span>
          </span>
        )
      })}
    </nav>
  )
}
