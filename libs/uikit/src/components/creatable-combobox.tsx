'use client'

import * as React from 'react'
import { compact } from '@agentbull/active-support'
import {
  Combobox,
  ComboboxCollection,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList
} from './combobox'

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
  ariaLabel,
  clearLabel,
  value,
  options,
  placeholder,
  emptyLabel = 'No matches',
  createLabel = value => `Use "${value}"`,
  onValueChange,
  disabled,
  required,
  triggerLabel
}: {
  ariaLabel?: string
  clearLabel?: string
  value?: string | null
  options: CreatableComboboxOption[]
  placeholder?: string
  emptyLabel?: string
  createLabel?: (value: string) => string
  onValueChange: (value: string) => void
  disabled?: boolean
  required?: boolean
  triggerLabel?: string
}) {
  const currentValue = value ?? ''
  const selected = React.useMemo(
    () =>
      currentValue === ''
        ? null
        : options.find(option => option.value === currentValue) || { value: currentValue, label: currentValue },
    [currentValue, options]
  )
  const selectedInputValue = displayValue(selected)
  const [inputValue, setInputValue] = React.useState(selectedInputValue)

  React.useEffect(() => {
    setInputValue(selectedInputValue)
  }, [selectedInputValue])

  const trimmedInput = inputValue.trim()
  const matchedInputOption = optionForInput(options, trimmedInput)
  const inputMatchesValue = selected ? optionMatchesInput(selected, trimmedInput) : false
  const visibleOptions = filterCreatableComboboxOptions(options, inputValue, selected)
  const canCreate = trimmedInput !== '' && !matchedInputOption && !inputMatchesValue
  // The create row is inserted before matches so keyboard users can commit a
  // new exact value without moving through every partial search result.
  const items: ComboboxOption[] = canCreate
    ? [{ value: trimmedInput, label: createLabel(trimmedInput), creatable: true }, ...visibleOptions]
    : visibleOptions

  function commitInput() {
    if (matchedInputOption) {
      setInputValue(displayValue(matchedInputOption))
      if (matchedInputOption.value !== currentValue) onValueChange(matchedInputOption.value)
    } else if (canCreate) {
      setInputValue(trimmedInput)
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
        const nextValue = item?.value ?? ''
        setInputValue(displayValue(item))
        onValueChange(nextValue)
      }}>
      <ComboboxInput
        aria-label={ariaLabel}
        clearLabel={clearLabel}
        placeholder={placeholder}
        showClear
        required={required}
        triggerLabel={triggerLabel}
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
          <ComboboxCollection>
            {(option: ComboboxOption) => (
              <ComboboxItem key={`${option.creatable ? 'create' : 'option'}:${option.value}`} value={option}>
                <span className="flex min-w-0 flex-col">
                  <span className="truncate leading-5">{option.label || option.value}</span>
                  {option.description ? (
                    <span className="truncate text-xs leading-4 text-muted-foreground">{option.description}</span>
                  ) : option.creatable ? (
                    <span className="truncate text-xs leading-4 text-muted-foreground">{option.value}</span>
                  ) : null}
                </span>
              </ComboboxItem>
            )}
          </ComboboxCollection>
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

export function filterCreatableComboboxOptions(
  options: CreatableComboboxOption[],
  input: string,
  selected: CreatableComboboxOption | null
) {
  const trimmedInput = input.trim()
  const normalizedInput = trimmedInput.toLowerCase()
  if (normalizedInput === '' || (selected && optionMatchesInput(selected, trimmedInput))) return options

  return options.filter(option => {
    const searchable = compact([option.value, option.label, option.description]).join('\n').toLowerCase()
    return searchable.includes(normalizedInput)
  })
}

function displayValue(option: ComboboxOption | null) {
  if (!option) return ''
  return option.creatable ? option.value : option.label || option.value
}
