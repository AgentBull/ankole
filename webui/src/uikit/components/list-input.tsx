"use client"

import { RiAddLine, RiCloseLine } from "@remixicon/react"
import * as React from "react"
import { Button } from "@/uikit/components/button"
import {
  Combobox,
  ComboboxChip,
  ComboboxChips,
  ComboboxChipsInput,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxItem,
  ComboboxList,
  ComboboxValue,
  useComboboxAnchor,
} from "@/uikit/components/combobox"
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from "@/uikit/components/input-group"
import { Textarea } from "@/uikit/components/textarea"
import { cn } from "@/uikit/lib/utils"

export type ListInputOption = {
  value: string
  label?: string
}

export function StringListInput({
  value,
  onValueChange,
  placeholder,
  addLabel = "Add",
  removeLabel = "Remove",
}: {
  value: string[]
  onValueChange: (value: string[]) => void
  placeholder?: string
  addLabel?: string
  removeLabel?: string
}) {
  const [draft, setDraft] = React.useState("")

  function add(raw: string) {
    const next = raw.trim()
    if (!next || value.includes(next)) return
    onValueChange([...value, next])
    setDraft("")
  }

  function remove(item: string) {
    onValueChange(value.filter(current => current !== item))
  }

  function addMany(raw: string) {
    const items = raw
      .split(/[\n,]/)
      .map(item => item.trim())
      .filter(Boolean)

    if (items.length === 0) return

    onValueChange([...new Set([...value, ...items])])
    setDraft("")
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap gap-1.5">
        {value.map(item => (
          <span
            key={item}
            className="inline-flex h-7 max-w-full items-center gap-1 rounded-none bg-muted px-2 text-xs text-foreground">
            <span className="truncate">{item}</span>
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label={`${removeLabel}: ${item}`}
              className="size-5"
              onClick={() => remove(item)}>
              <RiCloseLine />
            </Button>
          </span>
        ))}
      </div>
      <InputGroup>
        <InputGroupInput
          value={draft}
          placeholder={placeholder}
          onChange={event => setDraft(event.target.value)}
          onPaste={event => {
            const text = event.clipboardData.getData("text")
            if (/[\n,]/.test(text)) {
              event.preventDefault()
              addMany(text)
            }
          }}
          onKeyDown={event => {
            if (event.key === "Enter" || event.key === ",") {
              event.preventDefault()
              add(draft)
            }
            if (event.key === "Backspace" && draft === "" && value.length > 0) {
              onValueChange(value.slice(0, -1))
            }
          }}
        />
        <InputGroupAddon align="inline-end">
          <InputGroupButton type="button" aria-label={addLabel} onClick={() => add(draft)}>
            <RiAddLine />
          </InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    </div>
  )
}

export function SelectListInput({
  value,
  options,
  onValueChange,
  placeholder,
  emptyLabel = "No matches",
}: {
  value: string[]
  options: ListInputOption[]
  onValueChange: (value: string[]) => void
  placeholder?: string
  emptyLabel?: string
}) {
  const anchor = useComboboxAnchor()
  const selected = options.filter(option => value.includes(option.value))

  return (
    <div ref={anchor}>
      <Combobox
        multiple
        items={options}
        value={selected}
        itemToStringValue={item => item.value}
        itemToStringLabel={item => item.label || item.value}
        isItemEqualToValue={(item, current) => item.value === current.value}
        onValueChange={items => onValueChange(normalizeOptions(items).map(item => item.value))}>
        <ComboboxChips>
          <ComboboxValue>
            {(items: ListInputOption[]) => (
              <>
                {items?.map(item => (
                  <ComboboxChip key={item.value}>{item.label || item.value}</ComboboxChip>
                ))}
                <ComboboxChipsInput placeholder={placeholder} />
              </>
            )}
          </ComboboxValue>
        </ComboboxChips>
        <ComboboxContent anchor={anchor}>
          <ComboboxList>
            <ComboboxEmpty>{emptyLabel}</ComboboxEmpty>
            {options.map(option => (
              <ComboboxItem key={option.value} value={option}>
                {option.label || option.value}
              </ComboboxItem>
            ))}
          </ComboboxList>
        </ComboboxContent>
      </Combobox>
    </div>
  )
}

export function JsonListInput({
  value,
  onValueChange,
  addLabel = "Add item",
  removeLabel = "Remove item",
}: {
  value: unknown[]
  onValueChange: (value: unknown[]) => void
  addLabel?: string
  removeLabel?: string
}) {
  function update(index: number, raw: string) {
    const next = [...value]
    next[index] = parseJson(raw)
    onValueChange(next)
  }

  return (
    <div className="flex flex-col gap-3">
      {value.map((item, index) => (
        <div key={index} className="flex items-start gap-2">
          <Textarea
            className={cn("min-h-20 font-mono text-xs")}
            defaultValue={jsonText(item)}
            onBlur={event => update(index, event.target.value)}
          />
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            aria-label={`${removeLabel} ${index + 1}`}
            onClick={() => onValueChange(value.filter((_item, itemIndex) => itemIndex !== index))}>
            <RiCloseLine />
          </Button>
        </div>
      ))}
      <Button type="button" variant="outline" size="sm" onClick={() => onValueChange([...value, {}])}>
        <RiAddLine data-icon="inline-start" />
        {addLabel}
      </Button>
    </div>
  )
}

function normalizeOptions(items: ListInputOption[] | ListInputOption | null) {
  if (Array.isArray(items)) return items
  if (items) return [items]
  return []
}

function jsonText(value: unknown) {
  if (typeof value === "string") return value
  return JSON.stringify(value, null, 2)
}

function parseJson(value: string) {
  const trimmed = value.trim()
  if (!trimmed) return {}

  try {
    return JSON.parse(trimmed)
  } catch {
    return value
  }
}
