'use client'

import * as React from 'react'
import { compact } from '@pleisto/active-support'
import { Combobox, ComboboxContent, ComboboxEmpty, ComboboxInput, ComboboxItem, ComboboxList } from './combobox'

export type CreatableComboboxOption = {
  value: string
  label?: string
  description?: string
}

type ComboboxOption = CreatableComboboxOption & {
  creatable?: boolean
}

/** Selects a known option or commits the current input as a new option. */
export function CreatableCombobox({
  value,
  options,
  placeholder,
  emptyLabel = 'No matches',
  createLabel = value => `Use "${value}"`,
  onValueChange,
  disabled,
  required
}: {
  value: string
  options: CreatableComboboxOption[]
  placeholder?: string
  emptyLabel?: string
  createLabel?: (value: string) => string
  onValueChange: (value: string) => void
  disabled?: boolean
  required?: boolean
}) {
  const [inputValue, setInputValue] = React.useState(value)

  React.useEffect(() => {
    setInputValue(value)
  }, [value])

  const selected = React.useMemo(
    () => options.find(option => option.value === value) || { value, label: value },
    [options, value]
  )
  const trimmedInput = inputValue.trim()
  const normalizedInput = trimmedInput.toLowerCase()
  const matchedInputOption = optionForInput(options, trimmedInput)
  const inputMatchesValue = optionMatchesInput(selected, trimmedInput)
  const visibleOptions =
    normalizedInput === ''
      ? options
      : options.filter(option => {
          const searchable = compact([option.value, option.label, option.description]).join('\n').toLowerCase()
          return searchable.includes(normalizedInput)
        })
  const canCreate = trimmedInput !== '' && !matchedInputOption && !inputMatchesValue
  // The create row is inserted before matches so keyboard users can commit a
  // new exact value without moving through every partial search result.
  const items: ComboboxOption[] = canCreate
    ? [{ value: trimmedInput, label: createLabel(trimmedInput), creatable: true }, ...visibleOptions]
    : visibleOptions

  function commitInput() {
    if (matchedInputOption) {
      if (matchedInputOption.value !== value) onValueChange(matchedInputOption.value)
    } else if (canCreate) {
      onValueChange(trimmedInput)
    }
  }

  return (
    <Combobox
      items={items}
      value={selected}
      inputValue={inputValue}
      disabled={disabled}
      itemToStringValue={item => item.value}
      itemToStringLabel={item => item.label || item.value}
      isItemEqualToValue={(item, current) => item.value === current.value}
      onInputValueChange={setInputValue}
      onValueChange={item => {
        if (item) {
          setInputValue(item.value)
          onValueChange(item.value)
        }
      }}>
      <ComboboxInput
        placeholder={placeholder}
        showClear
        required={required}
        onBlur={commitInput}
        onKeyDown={event => {
          if (event.key === 'Enter' && canCreate) {
            event.preventDefault()
            commitInput()
          }
        }}
      />
      <ComboboxContent>
        <ComboboxList>
          <ComboboxEmpty>{emptyLabel}</ComboboxEmpty>
          {items.map(option => (
            <ComboboxItem key={`${option.creatable ? 'create' : 'option'}:${option.value}`} value={option}>
              <span className="flex min-w-0 flex-col">
                <span className="truncate">{option.label || option.value}</span>
                {option.description ? (
                  <span className="truncate text-xs text-muted-foreground">{option.description}</span>
                ) : option.creatable ? (
                  <span className="truncate text-xs text-muted-foreground">{option.value}</span>
                ) : null}
              </span>
            </ComboboxItem>
          ))}
        </ComboboxList>
      </ComboboxContent>
    </Combobox>
  )
}

function optionForInput(options: CreatableComboboxOption[], input: string) {
  return options.find(option => optionMatchesInput(option, input))
}

function optionMatchesInput(option: CreatableComboboxOption, input: string) {
  return option.value.trim() === input || option.label?.trim() === input
}
