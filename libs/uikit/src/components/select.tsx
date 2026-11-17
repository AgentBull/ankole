import {
  Select as SelectPrimitive,
  SelectContent as SelectContentPrimitive,
  SelectGroup as SelectGroupPrimitive,
  SelectGroupLabel,
  SelectItem as SelectItemPrimitive,
  SelectItemIndicator,
  SelectList,
  SelectSeparator as SelectSeparatorPrimitive,
  SelectTrigger as SelectTriggerPrimitive,
  SelectValue as SelectValuePrimitive,
  type SelectOptions,
  type SelectProps as SelectPrimitiveProps
} from '@ui-sdk/react/select'
import { CaretDownFilled, ChevronDownRegular, ChevronUpRegular } from '../icons'
import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

/** Labels for values, keyed by value or listed as pairs. A label may be any node, like an icon beside a name. */
type SelectItems = Record<string, React.ReactNode> | ReadonlyArray<{ label: React.ReactNode; value: unknown }>

/**
 * Carries the options and their loading state from `Select` to `SelectValue`, which shows the selected option's own
 * label, icons included. While the caller still loads the options, `SelectValue` shows a skeleton for a value that
 * matches no option instead of an ID that turns into a name a moment later.
 */
const SelectOptionsContext = React.createContext<{ items: SelectItems; loading: boolean } | null>(null)

/**
 * The attributes a form field gives the whole select, such as the `id` its label points at. ui-sdk's select root
 * renders no element, so the trigger, the control a label names, carries them.
 */
type SelectControlProps = Pick<React.ComponentProps<'button'>, 'id' | 'aria-describedby' | 'aria-invalid'>
const SelectControlContext = React.createContext<SelectControlProps>({})

type SelectChangeDetails = Parameters<NonNullable<Extract<SelectOptions, { multiple?: false }>['onValueChange']>>[1]

/** The props of ui-sdk's select, with the value typed by the options the caller passes, as callers infer it. */
type SelectProps<Value, Multiple extends boolean | undefined> = Omit<
  SelectPrimitiveProps,
  | 'items'
  | 'value'
  | 'defaultValue'
  | 'onValueChange'
  | 'multiple'
  | 'itemToValue'
  | 'itemToLabel'
  | 'isItemEqualToValue'
> & {
  multiple?: Multiple
  itemToValue?: (value: Value) => string
  itemToLabel?: (value: Value) => string
  isItemEqualToValue?: (itemValue: Value, value: Value) => boolean
  value?: (Multiple extends true ? readonly Value[] : Value) | null
  defaultValue?: (Multiple extends true ? readonly Value[] : Value) | null
  onValueChange?: (value: Multiple extends true ? Value[] : Value | null, details: SelectChangeDetails) => void
  /** Labels for values; by default, the `SelectItem` children. */
  items?: SelectItems
  /** The options are still loading, so a value without a matching option shows a skeleton, not its raw value. */
  loading?: boolean
} & SelectControlProps

function Select<Value, Multiple extends boolean | undefined = false>(props: SelectProps<Value, Multiple>) {
  const {
    children,
    items,
    loading = false,
    id,
    'aria-describedby': describedBy,
    'aria-invalid': invalid,
    ...rootProps
  } = props
  const resolvedItems = React.useMemo(() => items ?? collectSelectItems<Value>(children), [children, items])
  const optionsContext = React.useMemo(() => ({ items: resolvedItems, loading }), [resolvedItems, loading])
  const popupContainer = usePopupContainer(rootProps.container)
  const controlContext = React.useMemo(
    () => ({ id, 'aria-describedby': describedBy, 'aria-invalid': invalid }),
    [id, describedBy, invalid]
  )

  return (
    <SelectOptionsContext.Provider value={optionsContext}>
      <SelectControlContext.Provider value={controlContext}>
        <SelectPrimitive<Value, Multiple>
          {...(rootProps as unknown as React.ComponentProps<typeof SelectPrimitive<Value, Multiple>>)}
          container={popupContainer}>
          {children}
        </SelectPrimitive>
      </SelectControlContext.Provider>
    </SelectOptionsContext.Provider>
  )
}

function selectItemLabel(items: SelectItems, value: unknown): { found: boolean; label?: React.ReactNode } {
  if (Array.isArray(items)) {
    const item = items.find(entry => Object.is(entry.value, value))
    return item ? { found: true, label: item.label } : { found: false }
  }
  const key = String(value)
  return Object.hasOwn(items, key)
    ? { found: true, label: (items as Record<string, React.ReactNode>)[key] }
    : { found: false }
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

function SelectGroup({
  className,
  ...props
}: Omit<React.ComponentProps<typeof SelectGroupPrimitive>, 'className'> & { className?: string }) {
  return <SelectGroupPrimitive className={cn('scroll-my-1', className)} {...props} />
}

/**
 * The selected option's label, or the placeholder while nothing is selected. A children function receives the
 * selected value. A value that matches no option shows as its raw string, except while the options load.
 */
function SelectValue({
  children,
  className,
  placeholder,
  ...props
}: Omit<React.ComponentProps<typeof SelectValuePrimitive>, 'children' | 'className' | 'placeholder'> & {
  children?: React.ReactNode | ((value: any) => React.ReactNode)
  className?: string
  placeholder?: React.ReactNode
}) {
  const options = React.useContext(SelectOptionsContext)
  const content = ({ value, label }: { value: unknown; label: string }) => {
    if (value == null || (Array.isArray(value) && value.length === 0)) return placeholder
    const item = options && !Array.isArray(value) ? selectItemLabel(options.items, value) : { found: false }
    // An empty string is a real option value only when an item declares it. Otherwise it means "nothing chosen yet",
    // and a function child or a loading list shows the placeholder for it too, so none of them paints a raw key.
    if (
      value === '' &&
      placeholder != null &&
      (typeof children === 'function' || options?.loading || (options != null && !item.found))
    ) {
      return placeholder
    }
    if (typeof children === 'function') return children(value)
    if (Array.isArray(value)) return children ?? label
    if (options?.loading && !item.found) {
      return <span data-slot="skeleton" aria-hidden className="inline-block h-4 w-24 rounded-mini bg-skeleton" />
    }
    return children ?? (item.found ? item.label : String(value))
  }
  return (
    <SelectValuePrimitive className={cn('flex min-w-0 flex-1 truncate text-left', className)} {...props}>
      {content}
    </SelectValuePrimitive>
  )
}

// A field select is a slot that holds a value. A ghost select sits in a header or toolbar band, where a
// slot would read as an input: it is ink text with a chevron and shows a wash only on hover. The `toolbar` size is
// the 32px selector of a shell toolbar, such as the composer's: a label of 12px text and a 12px filled arrow whose
// wash, like a toolbar button's, tints only the box that holds them. When the toolbar runs out of room, the value
// ends in an ellipsis and gives up its width, while the arrow and the padding around it stay, so the selector
// never narrows past 32px.
const selectTriggerVariants = cva(
  "flex w-fit max-w-full min-w-0 cursor-pointer items-center justify-between gap-2 rounded-control border px-3 py-0 text-sm leading-5 whitespace-nowrap transition-[background-color,color] duration-(--duration-feedback) disabled:cursor-not-allowed disabled:text-fg-disabled data-placeholder:text-fg-placeholder data-[size=default]:h-control-md data-[size=sm]:h-control-sm *:data-[slot=select-value]:line-clamp-1 *:data-[slot=select-value]:flex *:data-[slot=select-value]:items-center *:data-[slot=select-value]:gap-2 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 data-[size=toolbar]:h-control-md data-[size=toolbar]:min-w-8 data-[size=toolbar]:gap-1 data-[size=toolbar]:rounded-[calc(var(--radius-micro)+var(--spacing)*1.5)] data-[size=toolbar]:bg-clip-content data-[size=toolbar]:px-1.75 data-[size=toolbar]:py-1.25 data-[size=toolbar]:text-50 data-[size=toolbar]:font-normal data-[size=toolbar]:*:data-[slot=select-value]:block data-[size=toolbar]:*:data-[slot=select-value]:truncate",
  {
    variants: {
      variant: {
        field:
          'border-field-border bg-field outline-none hover:bg-field-hover focus-visible:border-control-edge focus-visible:border-b-ring focus-visible:bg-page focus-visible:shadow-[inset_0_-1px_0_var(--color-ring)] disabled:border-transparent disabled:bg-field aria-invalid:bg-(--field-invalid) data-invalid:bg-(--field-invalid)',
        ghost:
          'border-transparent bg-transparent text-fg-secondary hover:bg-layer-hover hover:text-fg-primary focus-visible:outline-offset-1 data-open:bg-layer-hover data-open:text-fg-primary'
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
}: Omit<React.ComponentProps<typeof SelectTriggerPrimitive>, 'className' | 'children'> &
  VariantProps<typeof selectTriggerVariants> & {
    className?: string
    children?: React.ReactNode
    size?: 'sm' | 'default' | 'toolbar'
  }) {
  const control = React.useContext(SelectControlContext)
  return (
    <SelectTriggerPrimitive
      {...control}
      data-size={size}
      data-variant={variant}
      className={cn('group/select-trigger', selectTriggerVariants({ variant }), className)}
      {...props}>
      {children}
      {size === 'toolbar' ? (
        <CaretDownFilled aria-hidden className="pointer-events-none size-3" />
      ) : (
        <ChevronDownRegular
          aria-hidden
          className="pointer-events-none size-3.5 text-fg-secondary motion-safe:transition-transform motion-safe:duration-[240ms] motion-safe:ease-(--ease-segment) group-data-open/select-trigger:rotate-180"
        />
      )}
    </SelectTriggerPrimitive>
  )
}

/**
 * The list of a select. It is ceramic, like every menu. A select in the composer's toolbar opens on the
 * `composer` surface: the same ceramic with rows that run from edge to edge.
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
}: Omit<React.ComponentProps<typeof SelectContentPrimitive>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
  emptyLabel?: React.ReactNode
  surface?: 'ceramic' | 'composer'
}) {
  const isEmpty = collectSelectItems(children).length === 0

  return (
    <SelectContentPrimitive
      side={side}
      sideOffset={sideOffset}
      align={align}
      alignOffset={alignOffset}
      alignItemWithTrigger={alignItemWithTrigger}
      data-align-trigger={alignItemWithTrigger}
      className={cn(
        'ceramic-menu relative isolate z-50 outline-none max-h-(--available-height) w-(--anchor-width) min-w-36 origin-(--transform-origin) overflow-x-hidden overflow-y-auto text-fg-primary transition-none data-starting-style:opacity-0 data-ending-style:opacity-0',
        surface === 'composer' ? 'composer-menu' : 'ceramic ceramic-primary p-1',
        className
      )}
      {...props}>
      <SelectList className="relative isolate">
        <SelectHighlight />
        {isEmpty && emptyLabel ? (
          <div
            role="option"
            aria-disabled="true"
            aria-selected="false"
            data-slot="select-empty"
            className="px-4 py-3 text-sm text-fg-secondary">
            {emptyLabel}
          </div>
        ) : (
          children
        )}
      </SelectList>
    </SelectContentPrimitive>
  )
}

function SelectHighlight() {
  const ref = React.useRef<HTMLSpanElement>(null)
  React.useLayoutEffect(() => {
    const highlight = ref.current
    const list = highlight?.parentElement
    if (!highlight || !list) return

    // ui-sdk owns the active option for pointer, keyboard and type-ahead. The highlight follows that option.
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

/** The heading of a `SelectGroup`. */
function SelectLabel({
  className,
  ...props
}: Omit<React.ComponentProps<typeof SelectGroupLabel>, 'className'> & { className?: string }) {
  return <SelectGroupLabel className={cn('menu-group-label', className)} {...props} />
}

function SelectItem<Value = string>({
  className,
  children,
  ...props
}: Omit<React.ComponentProps<typeof SelectItemPrimitive<Value>>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
}) {
  return (
    <SelectItemPrimitive<Value>
      className={cn(
        "relative flex min-h-10 w-full cursor-pointer items-center gap-2.5 rounded-control py-2 pr-8 pl-2.5 text-sm leading-5 outline-hidden select-none data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 *:[span]:last:flex *:[span]:last:items-center *:[span]:last:gap-2",
        className
      )}
      {...props}>
      <span className="flex flex-1 shrink-0 gap-2 whitespace-nowrap">{children}</span>
      <SelectItemIndicator
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
      </SelectItemIndicator>
    </SelectItemPrimitive>
  )
}

function SelectSeparator({
  className,
  ...props
}: Omit<React.ComponentProps<typeof SelectSeparatorPrimitive>, 'className'> & { className?: string }) {
  return (
    <SelectSeparatorPrimitive
      className={cn('pointer-events-none mx-2.5 my-1.5 h-px bg-divider-overlay', className)}
      {...props}
    />
  )
}

// shortcut: ui-sdk scrolls a long list natively and has no scroll arrows, so these two only draw the arrow band;
// give them hover scrolling if a caller places one.
function SelectScrollUpButton({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      aria-hidden
      data-slot="select-scroll-up-button"
      className={cn(
        "top-0 z-10 flex w-full cursor-pointer items-center justify-center bg-[rgb(var(--ceramic-body))] py-1 [&_svg:not([class*='size-'])]:size-3.5",
        className
      )}
      {...props}>
      <ChevronUpRegular />
    </div>
  )
}

function SelectScrollDownButton({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      aria-hidden
      data-slot="select-scroll-down-button"
      className={cn(
        "bottom-0 z-10 flex w-full cursor-pointer items-center justify-center bg-[rgb(var(--ceramic-body))] py-1 [&_svg:not([class*='size-'])]:size-3.5",
        className
      )}
      {...props}>
      <ChevronDownRegular />
    </div>
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
