import { Select as SelectPrimitive } from '@base-ui/react/select'
import { RiArrowDownSLine, RiArrowUpSLine, RiCheckLine } from '@remixicon/react'
import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '../lib/utils'

const SelectThemeContext = React.createContext<{
  theme: string | undefined
  setTheme: React.Dispatch<React.SetStateAction<string | undefined>>
} | null>(null)

function Select<Value, Multiple extends boolean | undefined = false>(
  props: SelectPrimitive.Root.Props<Value, Multiple>
) {
  const { children, items, ...rootProps } = props
  const [theme, setTheme] = React.useState<string | undefined>()
  const themeContext = React.useMemo(() => ({ theme, setTheme }), [theme])
  const resolvedItems = React.useMemo(() => items ?? collectSelectItems<Value>(children), [children, items])

  return (
    <SelectThemeContext.Provider value={themeContext}>
      <SelectPrimitive.Root {...rootProps} items={resolvedItems}>
        {children}
      </SelectPrimitive.Root>
    </SelectThemeContext.Provider>
  )
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
  return (
    <SelectPrimitive.Value
      data-slot="select-value"
      className={cn('flex min-w-0 flex-1 truncate text-left', className)}
      placeholder={placeholder}
      {...props}>
      {guarded}
    </SelectPrimitive.Value>
  )
}

// A field select is a slot that holds a value. A ghost select sits in a header or toolbar band, where a
// slot would read as an input: it is ink text with a chevron and shows a wash only on hover.
const selectTriggerVariants = cva(
  "flex w-fit max-w-full min-w-0 cursor-pointer items-center justify-between gap-2 rounded-control border px-3 py-0 text-sm leading-5 whitespace-nowrap transition-[background-color,color] duration-(--duration-feedback) disabled:cursor-not-allowed disabled:text-fg-disabled data-placeholder:text-fg-placeholder data-[size=default]:h-8 data-[size=sm]:h-7 *:data-[slot=select-value]:line-clamp-1 *:data-[slot=select-value]:flex *:data-[slot=select-value]:items-center *:data-[slot=select-value]:gap-2 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
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
    size?: 'sm' | 'default'
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
      className={cn(selectTriggerVariants({ variant }), className)}
      {...props}>
      {children}
      <SelectPrimitive.Icon
        render={<RiArrowDownSLine className="pointer-events-none size-3.5 text-muted-foreground" />}
      />
    </SelectPrimitive.Trigger>
  )
}

function SelectContent({
  className,
  children,
  emptyLabel,
  side = 'bottom',
  sideOffset = 4,
  align = 'center',
  alignOffset = 0,
  alignItemWithTrigger = false,
  ...props
}: SelectPrimitive.Popup.Props &
  Pick<SelectPrimitive.Positioner.Props, 'align' | 'alignOffset' | 'side' | 'sideOffset' | 'alignItemWithTrigger'> & {
    emptyLabel?: React.ReactNode
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
            'ceramic ceramic-primary ceramic-menu relative isolate z-50 outline-none max-h-(--available-height) p-1 w-(--anchor-width) min-w-36 origin-(--transform-origin) overflow-x-hidden overflow-y-auto text-popover-foreground transition-none data-starting-style:opacity-0 data-ending-style:opacity-0',
            className
          )}
          {...props}>
          <SelectScrollUpButton />
          <SelectPrimitive.List>
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

function SelectLabel({ className, ...props }: SelectPrimitive.GroupLabel.Props) {
  return (
    <SelectPrimitive.GroupLabel
      data-slot="select-label"
      className={cn('px-2.5 py-2 text-xs text-muted-foreground', className)}
      {...props}
    />
  )
}

function SelectItem({ className, children, ...props }: SelectPrimitive.Item.Props) {
  return (
    <SelectPrimitive.Item
      data-slot="select-item"
      className={cn(
        "relative flex min-h-10 w-full cursor-pointer items-center gap-2.5 rounded-control py-2 pr-8 pl-2.5 text-sm leading-5 outline-hidden select-none focus:bg-(--menu-hover) data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 *:[span]:last:flex *:[span]:last:items-center *:[span]:last:gap-2",
        className
      )}
      {...props}>
      <SelectPrimitive.ItemText className="flex flex-1 shrink-0 gap-2 whitespace-nowrap">
        {children}
      </SelectPrimitive.ItemText>
      <SelectPrimitive.ItemIndicator
        render={<span className="pointer-events-none absolute right-2 flex size-4 items-center justify-center" />}>
        <RiCheckLine className="pointer-events-none" />
      </SelectPrimitive.ItemIndicator>
    </SelectPrimitive.Item>
  )
}

function SelectSeparator({ className, ...props }: SelectPrimitive.Separator.Props) {
  return (
    <SelectPrimitive.Separator
      data-slot="select-separator"
      className={cn('pointer-events-none mx-2.5 my-1.5 h-px bg-(--menu-field-edge)', className)}
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
      <RiArrowUpSLine />
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
      <RiArrowDownSLine />
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
