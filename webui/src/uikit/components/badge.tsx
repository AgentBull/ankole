import { mergeProps } from "@base-ui/react/merge-props"
import { useRender } from "@base-ui/react/use-render"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/uikit/lib/utils"

const badgeVariants = cva(
  "group/badge inline-flex h-6 min-w-8 max-w-52 shrink-0 items-center justify-center gap-1 overflow-hidden rounded-full border border-transparent px-2 text-xs leading-none font-normal tracking-normal whitespace-nowrap normal-case transition-colors focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 aria-invalid:border-destructive aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 [&>svg]:pointer-events-none [&>svg]:size-3.5!",
  {
    variants: {
      variant: {
        default:
          "bg-brand-20 text-brand-70 hover:bg-brand-30 [a]:hover:text-brand-80 dark:bg-brand-80 dark:text-brand-20 dark:hover:bg-brand-70",
        secondary:
          "bg-gray-20 text-gray-100 hover:bg-gray-30 [a]:hover:text-gray-100 dark:bg-gray-70 dark:text-gray-10 dark:hover:bg-gray-60",
        destructive:
          "bg-red-20 text-red-70 hover:bg-red-30 focus-visible:ring-destructive/20 [a]:hover:text-red-80 dark:bg-red-80 dark:text-red-20 dark:hover:bg-red-70 dark:focus-visible:ring-destructive/40",
        outline: "border-gray-40 bg-transparent text-foreground hover:bg-muted [a]:hover:text-foreground",
        ghost: "bg-transparent text-muted-foreground hover:bg-muted hover:text-foreground",
        link: "h-auto min-w-0 max-w-none rounded-none bg-transparent px-0 text-primary underline-offset-4 hover:underline",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
)

function Badge({
  className,
  variant = "default",
  render,
  ...props
}: useRender.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
  return useRender({
    defaultTagName: "span",
    props: mergeProps<"span">(
      {
        className: cn(badgeVariants({ variant }), className),
      },
      props,
    ),
    render,
    state: {
      slot: "badge",
      variant,
    },
  })
}

export { Badge, badgeVariants }
