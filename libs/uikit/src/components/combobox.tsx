'use client'

import {
  ComboboxChip as ComboboxChipPrimitive,
  ComboboxChipRemove,
  ComboboxChips as ComboboxChipsPrimitive,
  ComboboxClear as ComboboxClearPrimitive,
  ComboboxContent as ComboboxContentPrimitive,
  ComboboxEmpty as ComboboxEmptyPrimitive,
  ComboboxGroup as ComboboxGroupPrimitive,
  ComboboxGroupLabel,
  ComboboxInput as ComboboxInputPrimitive,
  ComboboxItem as ComboboxItemPrimitive,
  ComboboxItemIndicator,
  ComboboxList as ComboboxListPrimitive,
  Combobox as ComboboxPrimitive,
  ComboboxSeparator as ComboboxSeparatorPrimitive,
  ComboboxTrigger as ComboboxTriggerPrimitive,
  ComboboxValue as ComboboxValuePrimitive,
  type ListData
} from '@ui-sdk/react/combobox'
import { CheckmarkRegular, ChevronDownRegular, DismissRegular } from '../icons'
import * as React from 'react'
import { Button } from './button'
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from './input-group'
import { type PopupContainer, usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

/** The input group that `ComboboxInput` draws, which the popup lines up with instead of the bare text field. */
const ComboboxGroupContext = React.createContext<{
  group: HTMLElement | null
  setGroup: (group: HTMLElement | null) => void
} | null>(null)

/** The items the list shows, which `ComboboxCollection` renders. */
const ComboboxItemsContext = React.createContext<ListData<unknown>>([])

type ComboboxProps<Value, Multiple extends boolean | undefined> =
  React.ComponentProps<typeof ComboboxPrimitive<Value, Multiple>> extends infer Props
    ? Props extends unknown
      ? Omit<Props, 'items'> & { items?: readonly Value[] }
      : never
    : never

/**
 * A text field that filters a list. `items` lists the option values themselves, as objects or strings;
 * `itemToLabel` names each one for the field and for filtering, and `ComboboxCollection` renders the ones that match.
 */
function Combobox<Value, Multiple extends boolean | undefined = false>(rootProps: ComboboxProps<Value, Multiple>) {
  const { items, itemToLabel, children, container, ...props } = rootProps as {
    items?: readonly Value[]
    itemToLabel?: (value: Value) => string
    children?: React.ReactNode
    container?: PopupContainer
  }
  const [group, setGroup] = React.useState<HTMLElement | null>(null)
  const groupContext = React.useMemo(() => ({ group, setGroup }), [group])
  const popupContainer = usePopupContainer(container)
  const data = React.useMemo(
    () => items?.map(value => ({ value, label: itemToLabel ? itemToLabel(value) : String(value) })),
    [items, itemToLabel]
  )
  return (
    <ComboboxGroupContext.Provider value={groupContext}>
      <ComboboxPrimitive<Value, Multiple>
        {...(props as React.ComponentProps<typeof ComboboxPrimitive<Value, Multiple>>)}
        items={data}
        itemToLabel={itemToLabel}
        container={popupContainer}>
        {children}
      </ComboboxPrimitive>
    </ComboboxGroupContext.Provider>
  )
}

/** The selected value, or values with `multiple`; a children function receives them, like one chip per value. */
function ComboboxValue({
  children,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxValuePrimitive>, 'children'> & {
  children?: React.ReactNode | ((value: any) => React.ReactNode)
}) {
  return (
    <ComboboxValuePrimitive {...props}>
      {typeof children === 'function' ? state => children(state.value) : children}
    </ComboboxValuePrimitive>
  )
}

function ComboboxTrigger({
  className,
  children,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxTriggerPrimitive>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
}) {
  return (
    <ComboboxTriggerPrimitive
      className={cn("cursor-pointer disabled:cursor-not-allowed [&_svg:not([class*='size-'])]:size-4", className)}
      {...props}>
      {children}
      <ChevronDownRegular className="pointer-events-none size-4 text-fg-secondary" />
    </ComboboxTriggerPrimitive>
  )
}

function ComboboxClear({
  className,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxClearPrimitive>, 'className'> & { className?: string }) {
  return (
    <ComboboxClearPrimitive
      render={<InputGroupButton variant="ghost" size="icon-xs" />}
      className={cn('touch-target', className)}
      {...props}>
      <DismissRegular className="pointer-events-none" />
    </ComboboxClearPrimitive>
  )
}

function ComboboxInput({
  className,
  children,
  clearLabel = 'Clear selection',
  disabled,
  showTrigger = true,
  showClear = false,
  triggerLabel = 'Open options',
  ...props
}: Omit<React.ComponentProps<typeof ComboboxInputPrimitive>, 'className'> & {
  className?: string
  children?: React.ReactNode
  clearLabel?: string
  showTrigger?: boolean
  showClear?: boolean
  triggerLabel?: string
}) {
  const groupContext = React.useContext(ComboboxGroupContext)
  return (
    <InputGroup ref={groupContext?.setGroup} className={cn('w-auto', className)}>
      <ComboboxInputPrimitive render={<InputGroupInput disabled={disabled} />} {...props} />
      <InputGroupAddon align="inline-end">
        {showTrigger && (
          <InputGroupButton
            aria-label={triggerLabel}
            size="icon-xs"
            variant="ghost"
            render={<ComboboxTrigger />}
            data-slot="input-group-button"
            className="group-has-data-[slot=combobox-clear]/input-group:hidden data-open:bg-transparent"
            disabled={disabled}
          />
        )}
        {showClear && <ComboboxClear aria-label={clearLabel} disabled={disabled} />}
      </InputGroupAddon>
      {children}
    </InputGroup>
  )
}

/**
 * The popup of the list. It lines up with the input group that `ComboboxInput` draws, or with the chips around a
 * `ComboboxChipsInput`. `anchor` names another element.
 */
function ComboboxContent({
  className,
  side = 'bottom',
  sideOffset = 6,
  align = 'start',
  alignOffset = 0,
  anchor,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxContentPrimitive>, 'className' | 'anchor'> & {
  className?: string
  anchor?: React.ComponentProps<typeof ComboboxContentPrimitive>['anchor'] | React.RefObject<HTMLElement | null>
}) {
  const group = React.useContext(ComboboxGroupContext)?.group
  // ui-sdk already lines the popup up with the chips that a `useComboboxAnchor` ref marks.
  const target = anchor && typeof anchor === 'object' && 'current' in anchor ? undefined : (anchor ?? group)
  return (
    <ComboboxContentPrimitive
      side={side}
      sideOffset={sideOffset}
      align={align}
      alignOffset={alignOffset}
      anchor={target}
      data-chips={!!anchor}
      className={cn(
        'ceramic ceramic-primary ceramic-menu group/combobox-content relative outline-none max-h-(--available-height) w-(--anchor-width) max-w-(--available-width) origin-(--transform-origin) overflow-hidden text-fg-primary transition-none [--list-height:var(--available-height)] *:data-[slot=input-group]:m-1 *:data-[slot=input-group]:w-auto data-starting-style:opacity-0 data-ending-style:opacity-0',
        className
      )}
      {...props}
    />
  )
}

function ComboboxList({
  className,
  children,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxListPrimitive>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
}) {
  return (
    <ComboboxListPrimitive
      className={cn(
        'thin-scrollbar max-h-[min(calc(--spacing(72)---spacing(9)),calc(var(--list-height)---spacing(9)))] scroll-py-1 overflow-y-auto overscroll-contain p-1 has-data-empty:p-0',
        className
      )}
      {...props}>
      {state => <ComboboxItemsContext.Provider value={state.items}>{children}</ComboboxItemsContext.Provider>}
    </ComboboxListPrimitive>
  )
}

function ComboboxItem<Value = string>({
  className,
  children,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxItemPrimitive<Value>>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
}) {
  return (
    <ComboboxItemPrimitive<Value>
      className={cn(
        "relative flex min-h-10 w-full cursor-pointer items-center gap-2.5 rounded-control py-2 pr-8 pl-2.5 text-sm leading-5 outline-hidden select-none data-highlighted:bg-(--layer-hover) data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}>
      {children}
      <ComboboxItemIndicator
        render={<span className="pointer-events-none absolute right-2 flex size-4 items-center justify-center" />}>
        <CheckmarkRegular className="pointer-events-none" />
      </ComboboxItemIndicator>
    </ComboboxItemPrimitive>
  )
}

function ComboboxGroup({ ...props }: React.ComponentProps<typeof ComboboxGroupPrimitive>) {
  return <ComboboxGroupPrimitive {...props} />
}

/** The heading of a `ComboboxGroup`. */
function ComboboxLabel({
  className,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxGroupLabel>, 'className'> & { className?: string }) {
  return <ComboboxGroupLabel className={cn('menu-group-label', className)} {...props} />
}

/** Renders each item that the list shows, inside `ComboboxList`. */
function ComboboxCollection({ children }: { children: (item: any, index: number) => React.ReactNode }) {
  const items = React.useContext(ComboboxItemsContext)
  return (
    <>
      {items.map((entry, index) =>
        children(typeof entry === 'object' && 'value' in entry ? entry.value : entry, index)
      )}
    </>
  )
}

function ComboboxEmpty({
  className,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxEmptyPrimitive>, 'className'> & { className?: string }) {
  return (
    <ComboboxEmptyPrimitive
      className={cn(
        'hidden w-full justify-center py-2 text-center text-sm text-fg-secondary data-empty:flex',
        className
      )}
      {...props}
    />
  )
}

function ComboboxSeparator({
  className,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxSeparatorPrimitive>, 'className'> & { className?: string }) {
  return <ComboboxSeparatorPrimitive className={cn('mx-2.5 my-1.5 h-px bg-divider-overlay', className)} {...props} />
}

function ComboboxChips({
  className,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxChipsPrimitive>, 'className'> & { className?: string }) {
  return (
    <ComboboxChipsPrimitive
      className={cn(
        'flex min-h-8 flex-wrap items-center gap-1 rounded-control border border-field-edge border-b-field-border bg-field bg-clip-padding px-3 py-[3px] text-sm leading-5 transition-[background-color] duration-(--duration-feedback) hover:bg-field-hover focus-within:border-control-edge focus-within:border-b-ring focus-within:bg-page focus-within:shadow-[inset_0_-1px_0_var(--color-ring)] has-aria-invalid:border-b-destructive has-aria-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)] has-data-[slot=combobox-chip]:pl-[3px]',
        className
      )}
      {...props}
    />
  )
}

/** One selected value, named by `value`, with a button that removes it. */
function ComboboxChip<Value = string>({
  className,
  children,
  removeLabel,
  showRemove = true,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxChipPrimitive<Value>>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
  removeLabel?: string
  showRemove?: boolean
}) {
  return (
    <ComboboxChipPrimitive<Value>
      className={cn(
        'flex h-6 w-fit items-center justify-center gap-1 rounded-mini border border-control-edge border-b-control-base bg-control px-2 text-xs font-medium whitespace-nowrap text-fg-primary has-disabled:pointer-events-none has-disabled:cursor-not-allowed has-disabled:border-border-subtle has-disabled:bg-field has-disabled:text-fg-disabled has-data-[slot=combobox-chip-remove]:pr-0',
        className
      )}
      {...props}>
      {children}
      {showRemove && (
        <ComboboxChipRemove
          aria-label={removeLabel}
          render={<Button variant="ghost" size="icon-xs" />}
          className="-ml-1 opacity-50 hover:opacity-100">
          <DismissRegular className="pointer-events-none" />
        </ComboboxChipRemove>
      )}
    </ComboboxChipPrimitive>
  )
}

function ComboboxChipsInput({
  className,
  ...props
}: Omit<React.ComponentProps<typeof ComboboxInputPrimitive>, 'className'> & { className?: string }) {
  return (
    <ComboboxInputPrimitive className={cn('min-w-16 flex-1 text-sm leading-5 outline-none', className)} {...props} />
  )
}

function useComboboxAnchor() {
  return React.useRef<HTMLDivElement | null>(null)
}

export {
  Combobox,
  ComboboxChip,
  ComboboxChips,
  ComboboxChipsInput,
  ComboboxCollection,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxGroup,
  ComboboxInput,
  ComboboxItem,
  ComboboxLabel,
  ComboboxList,
  ComboboxSeparator,
  ComboboxTrigger,
  ComboboxValue,
  useComboboxAnchor
}
