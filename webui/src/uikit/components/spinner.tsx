import { RiLoaderLine } from "@remixicon/react"
import { cn } from "@/uikit/lib/utils"

function Spinner({ className, ...props }: React.ComponentProps<"svg">) {
  return <RiLoaderLine role="status" aria-label="Loading" className={cn("size-4 animate-spin", className)} {...props} />
}

export { Spinner }
