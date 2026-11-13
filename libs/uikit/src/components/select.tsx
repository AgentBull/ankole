import { Select as SelectPrimitive } from '@base-ui/react/select'
import { CaretDownFilled, ChevronDownRegular, ChevronUpRegular } from '../icons'
import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '../lib/utils'

type SelectItems = SelectPrimitive.Root.Props<unknown, boolean | undefined>['items']

/**
 * Carries the options and their loading state from `Select` to `SelectValue`. Base UI shows a value that matches no
 * option as its raw string, so while the caller still loads the options, `SelectValue` shows a skeleton for such a
 * value instead of an ID that turns into a name a moment later.
 */
const SelectOptionsContext = React.createContext<{ items: SelectItems; loading: boolean } | null>(null)

const SelectThemeContext = React.createContext<{
  theme: string | undefined
  setTheme: React.Dispatch<React.SetStateAction<string | undefined>>
} | null>(null)

function Select<Value, Multiple extends boolean | undefined = false>(
  props: SelectPrimitive.Root.Props<Value, Multiple> & {
    /** The options are still loading, so a value without a matching option shows a skeleton, not its raw value. */
    loading?: boolean
  }
) {
  const { children, items, loading = false, ...rootProps } = props
  const [theme, setTheme] = React.useState<string | undefined>()
  const themeContext = React.useMemo(() => ({ theme, setTheme }), [theme])
  const resolvedItems = React.useMemo(() => items ?? collectSelectItems<Value>(children), [children, items])
  const optionsContext = React.useMemo(
    () => ({ items: resolvedItems as SelectItems, loading }),
    [resolvedItems, loading]
  )

  return (
    <SelectThemeContext.Provider value={themeContext}>
      <SelectOptionsContext.Provider value={optionsContext}>
        <SelectPrimitive.Root {...rootProps} items={resolvedItems}>
          {children}
        </SelectPrimitive.Root>
      </SelectOptionsContext.Provider>
    </SelectThemeContext.Provider>
  )
}

function selectItemLabel(items: SelectItems, value: unknown): { found: boolean; label?: React.ReactNode } {
  if (Array.isArray(items)) {
    const item = items.find(entry => Object.is(entry.value, value))
    return item ? { found: true, label: item.label } : { found: false }
  }
  if (items && typeof items === 'object') {
    const key = String(value)
    return Object.hasOwn(items, key)
      ? { found: true, label: (items as Record<string, React.ReactNode>)[key] }
      : { found: false }
  }
  return { found: false }
}

function collectSelectItems<Value>(children: React.ReactNode): ReadonlyArray<{ label: React.ReactNode; value: Value }> {
  const items: Array<{ label: React.ReactNode; value: Value }> = []

  React.Children.forEach(children, child => {
    if (!React.isValidElement<{ children?: React.ReactNode; value?: Value }>(child)) return

    if (child.type === SelectItem) {
      items.push({ label: child.props.children, value: child.props.value as Value })
      return
    }

    if (child.props.children) items.push(...collectSelectItems<Value>(child.props.children))
  })

  return items
}

function SelectGroup({ className, ...props }: SelectPrimitive.Group.Props) {
  return <SelectPrimitive.Group data-slot="select-group" className={cn('scroll-my-1', className)} {...props} />
}

function SelectValue({ children, className, placeholder, ...props }: SelectPrimitive.Value.Props) {
  // Base UI hands a children function the raw value even when nothing is
  // selected (null or ''), skipping the placeholder; keep the placeholder for
  // those values so a function child never paints "null" or a raw key.
  const guarded =
    typeof children === 'function' && placeholder != null
      ? (value: unknown) => (value == null || value === '' ? placeholder : children(value))
      : children
  const options = React.useContext(SelectOptionsContext)
  const content =
    options?.loading === true
      ? (value: unknown) => {
          if (value == null || value === '') return placeholder
          if (Array.isArray(value)) return typeof children === 'function' ? children(value) : children
          const item = selectItemLabel(options.items, value)
          if (!item.found) {
            return <span data-slot="skeleton" aria-hidden className="inline-block h-4 w-24 rounded-mini bg-skeleton" />
          }
          if (typeof children === 'function') return children(value)
          return children ?? item.label
        }
      : guarded
  return (
    <SelectPrimitive.Value
      data-slot="select-value"
      className={cn('flex min-w-0 flex-1 truncate text-left', className)}
      placeholder={placeholder}
      {...props}>
      {content}
    </SelectPrimitive.Value>
  )
}

// A field select is a slot that holds a value. A ghost select sits in a header or toolbar band, where a
// slot would read as an input: it is ink text with a chevron and shows a wash only on hover. The `toolbar` size is
// the 36px selector of a shell toolbar, such as the composer's: a label of 12px text and a 12px filled arrow whose
// wash, like a toolbar button's, tints only the box that holds them. When the toolbar runs out of room, the value
// ends in an ellipsis and gives up its width, while the arrow and the padding around it stay, so the selector
// never narrows past 32px.
const selectTriggerVariants = cva(
  "flex w-fit max-w-full min-w-0 cursor-pointer items-center justify-between gap-2 rounded-control border px-3 py-0 text-sm leading-5 whitespace-nowrap transition-[background-color,color] duration-(--duration-feedback) disabled:cursor-not-allowed disabled:text-fg-disabled data-placeholder:text-fg-placeholder data-[size=default]:h-8 data-[size=sm]:h-7 *:data-[slot=select-value]:line-clamp-1 *:data-[slot=select-value]:flex *:data-[slot=select-value]:items-center *:data-[slot=select-value]:gap-2 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 data-[size=toolbar]:h-9 data-[size=toolbar]:min-w-8 data-[size=toolbar]:gap-1 data-[size=toolbar]:rounded-[calc(var(--radius-micro)+var(--spacing)*2)] data-[size=toolbar]:bg-clip-content data-[size=toolbar]:p-1.75 data-[size=toolbar]:text-50 data-[size=toolbar]:font-normal data-[size=toolbar]:*:data-[slot=select-value]:block data-[size=toolbar]:*:data-[slot=select-value]:truncate",
  {
    variants: {
      variant: {
        field:
          'border-field-edge border-b-input bg-field outline-none hover:bg-field-hover focus-visible:border-control-edge focus-visible:border-b-ring focus-visible:bg-background focus-visible:shadow-[inset_0_-1px_0_var(--color-ring)] disabled:border-b-transparent disabled:bg-field aria-invalid:border-b-destructive aria-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)] data-invalid:border-b-destructive data-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)]',
        ghost:
          'border-transparent bg-transparent text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-offset-1 data-popup-open:bg-accent data-popup-open:text-foreground'
      }
    },
    defaultVariants: { variant: 'field' }
  }
)

function SelectTrigger({
  className,
  size = 'default',
  variant = 'field',
  children,
  ...props
}: SelectPrimitive.Trigger.Props &
  VariantProps<typeof selectTriggerVariants> & {
    size?: 'sm' | 'default' | 'toolbar'
  }) {
  const triggerRef = React.useRef<HTMLButtonElement | null>(null)
  const themeContext = React.useContext(SelectThemeContext)

  React.useLayoutEffect(() => {
    const theme = triggerRef.current?.closest<HTMLElement>('[data-theme]')?.getAttribute('data-theme') || undefined

    if (themeContext && themeContext.theme !== theme) {
      themeContext.setTheme(theme)
    }
  })

  return (
    <SelectPrimitive.Trigger
      ref={triggerRef}
      data-slot="select-trigger"
      data-size={size}
      data-variant={variant}
      className={cn('group/select-trigger', selectTriggerVariants({ variant }), className)}
      {...props}>
      {children}
      <SelectPrimitive.Icon
        render={
          size === 'toolbar' ? (
            <CaretDownFilled className="pointer-events-none size-3" />
          ) : (
            <ChevronDownRegular className="pointer-events-none size-3.5 text-muted-foreground motion-safe:transition-transform motion-safe:duration-[240ms] motion-safe:ease-(--ease-segment) group-data-popup-open/select-trigger:rotate-180" />
          )
        }
      />
    </SelectPrimitive.Trigger>
  )
}

/**
 * The list of a select. It is ceramic, like every menu. A select in the composer's toolbar opens on the
 * `composer` surface instead, so the list and the composer read as one object.
 */
function SelectContent({
  className,
  children,
  emptyLabel,
  surface = 'ceramic',
  side = 'bottom',
  sideOffset = 4,
  align = 'center',
  alignOffset = 0,
  alignItemWithTrigger = false,
  ...props
}: SelectPrimitive.Popup.Props &
  Pick<SelectPrimitive.Positioner.Props, 'align' | 'alignOffset' | 'side' | 'sideOffset' | 'alignItemWithTrigger'> & {
    emptyLabel?: React.ReactNode
    surface?: 'ceramic' | 'composer'
  }) {
  const themeContext = React.useContext(SelectThemeContext)
  const isEmpty = collectSelectItems(children).length === 0

  return (
    <SelectPrimitive.Portal data-theme={themeContext?.theme}>
      <SelectPrimitive.Positioner
        side={side}
        sideOffset={sideOffset}
        align={align}
        alignOffset={alignOffset}
        alignItemWithTrigger={alignItemWithTrigger}
        className="isolate z-50">
        <SelectPrimitive.Popup
          data-slot="select-content"
          data-align-trigger={alignItemWithTrigger}
          className={cn(
            'ceramic-menu relative isolate z-50 outline-none max-h-(--available-height) w-(--anchor-width) min-w-36 origin-(--transform-origin) overflow-x-hidden overflow-y-auto text-popover-foreground transition-none data-starting-style:opacity-0 data-ending-style:opacity-0',
            surface === 'composer' ? 'composer-menu' : 'ceramic ceramic-primary p-1',
            className
          )}
          {...props}>
          <SelectScrollUpButton />
          <SelectPrimitive.List className="relative isolate">
            <SelectHighlight />
            {isEmpty && emptyLabel ? (
              <div
                role="option"
                aria-disabled="true"
                aria-selected="false"
                data-slot="select-empty"
                className="px-4 py-3 text-sm text-muted-foreground">
                {emptyLabel}
              </div>
            ) : (
              children
            )}
          </SelectPrimitive.List>
          <SelectScrollDownButton />
        </SelectPrimitive.Popup>
      </SelectPrimitive.Positioner>
    </SelectPrimitive.Portal>
  )
}

function SelectHighlight() {
  const ref = React.useRef<HTMLSpanElement>(null)
  React.useLayoutEffect(() => {
    const highlight = ref.current
    const list = highlight?.parentElement
    if (!highlight || !list) return

    // Base UI owns the active option for pointer, keyboard and type-ahead. The highlight follows that option.
    let active: HTMLElement | null = null
    const place = () => {
      const option = list.querySelector<HTMLElement>('[data-slot="select-item"][data-highlighted]:not([data-disabled])')
      if (active !== option) {
        if (active) sizes.unobserve(active)
        if (option) sizes.observe(option)
        active = option
      }
      if (!option) {
        highlight.hidden = true
        return
      }

      // Layout offsets stay in list coordinates while the popup is scaled during entry.
      let top = option.offsetTop
      for (
        let parent = option.offsetParent;
        parent instanceof HTMLElement && parent !== list;
        parent = parent.offsetParent
      ) {
        top += parent.offsetTop + parent.clientTop
      }
      highlight.style.translate = `0 ${top}px`
      highlight.style.height = `${option.offsetHeight}px`
      highlight.hidden = false
    }
    const sizes = new ResizeObserver(place)
    sizes.observe(list)
    const options = new MutationObserver(place)
    options.observe(list, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['data-highlighted', 'data-disabled']
    })
    place()
    return () => {
      options.disconnect()
      sizes.disconnect()
    }
  }, [])

  return (
    <span
      ref={ref}
      aria-hidden
      hidden
      data-slot="select-highlight"
      className="pointer-events-none absolute inset-x-0 top-0 -z-10 rounded-control bg-(--layer-hover) motion-safe:transition-[translate,height] motion-safe:duration-[180ms] motion-safe:ease-(--ease-segment)"
    />
  )
}

function SelectLabel({ className, ...props }: SelectPrimitive.GroupLabel.Props) {
  return (
    <SelectPrimitive.GroupLabel data-slot="select-label" className={cn('menu-group-label', className)} {...props} />
  )
}

function SelectItem({ className, children, ...props }: SelectPrimitive.Item.Props) {
  return (
    <SelectPrimitive.Item
      data-slot="select-item"
      className={cn(
        "relative flex min-h-10 w-full cursor-pointer items-center gap-2.5 rounded-control py-2 pr-8 pl-2.5 text-sm leading-5 outline-hidden select-none data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 *:[span]:last:flex *:[span]:last:items-center *:[span]:last:gap-2",
        className
      )}
      {...props}>
      <SelectPrimitive.ItemText className="flex flex-1 shrink-0 gap-2 whitespace-nowrap">
        {children}
      </SelectPrimitive.ItemText>
      <SelectPrimitive.ItemIndicator
        render={<span className="pointer-events-none absolute right-2 flex size-4 items-center justify-center" />}>
        <svg
          data-slot="select-check"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden>
          <path d="M5 12.5 9.5 17 19 7" pathLength={1} />
        </svg>
      </SelectPrimitive.ItemIndicator>
    </SelectPrimitive.Item>
  )
}

function SelectSeparator({ className, ...props }: SelectPrimitive.Separator.Props) {
  return (
    <SelectPrimitive.Separator
      data-slot="select-separator"
      className={cn('pointer-events-none mx-2.5 my-1.5 h-px bg-divider-overlay', className)}
      {...props}
    />
  )
}

function SelectScrollUpButton({ className, ...props }: React.ComponentProps<typeof SelectPrimitive.ScrollUpArrow>) {
  return (
    <SelectPrimitive.ScrollUpArrow
      data-slot="select-scroll-up-button"
      className={cn(
        "top-0 z-10 flex w-full cursor-pointer items-center justify-center bg-[rgb(var(--ceramic-body))] bg-[linear-gradient(var(--ceramic-glaze),var(--ceramic-glaze))] py-1 [&_svg:not([class*='size-'])]:size-3.5",
        className
      )}
      {...props}>
      <ChevronUpRegular />
    </SelectPrimitive.ScrollUpArrow>
  )
}

function SelectScrollDownButton({ className, ...props }: React.ComponentProps<typeof SelectPrimitive.ScrollDownArrow>) {
  return (
    <SelectPrimitive.ScrollDownArrow
      data-slot="select-scroll-down-button"
      className={cn(
        "bottom-0 z-10 flex w-full cursor-pointer items-center justify-center bg-[rgb(var(--ceramic-body))] bg-[linear-gradient(var(--ceramic-glaze),var(--ceramic-glaze))] py-1 [&_svg:not([class*='size-'])]:size-3.5",
        className
      )}
      {...props}>
      <ChevronDownRegular />
    </SelectPrimitive.ScrollDownArrow>
  )
}

export {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectScrollDownButton,
  SelectScrollUpButton,
  SelectSeparator,
  SelectTrigger,
  SelectValue
}
