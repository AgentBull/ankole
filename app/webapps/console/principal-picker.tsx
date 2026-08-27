import {
  Combobox,
  ComboboxCollection,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList
} from '@ankole/uikit'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../common/request-errors'

export type PrincipalCandidate = { id: string; label?: string | null }

/**
 * Single-value principal picker, following the `AddMembershipPicker` combobox
 * pattern: the page owns the candidate query, this component owns the input
 * text and filtering. Unlike the membership picker it holds the selection.
 */
export function SinglePrincipalPicker({
  ariaLabel,
  candidates,
  error,
  isLoading,
  onChange,
  placeholder,
  value
}: {
  ariaLabel: string
  candidates: PrincipalCandidate[]
  error: unknown
  isLoading: boolean
  onChange: (id: string) => void
  placeholder: string
  value: string
}) {
  const { t } = useTranslation()
  const [inputValue, setInputValue] = useState('')
  const normalized = inputValue.trim().toLowerCase()
  const visible = normalized
    ? candidates.filter(candidate => `${candidate.label ?? ''}\n${candidate.id}`.toLowerCase().includes(normalized))
    : candidates
  // A stored selection that the candidate query has not returned yet must
  // still render as the selection instead of a cleared field.
  const selected = value ? (candidates.find(candidate => candidate.id === value) ?? { id: value }) : null

  return (
    <Combobox<PrincipalCandidate>
      items={visible}
      value={selected}
      inputValue={inputValue}
      // `visible` already matches label AND uid; the built-in filter would
      // re-filter by label only and hide uid matches.
      filter={null}
      itemToStringLabel={candidate => candidate.label ?? candidate.id}
      itemToStringValue={candidate => candidate.id}
      isItemEqualToValue={(candidate, current) => candidate.id === current.id}
      onInputValueChange={setInputValue}
      onValueChange={candidate => onChange(candidate?.id ?? '')}>
      <ComboboxInput
        aria-label={ariaLabel}
        className="w-full"
        clearLabel={t('common.clear')}
        placeholder={selected ? (selected.label ?? selected.id) : placeholder}
        showClear
      />
      <ComboboxContent>
        <ComboboxList>
          <ComboboxEmpty>
            {error ? requestErrorMessage(error) : isLoading ? t('common.loading') : t('common.select_empty')}
          </ComboboxEmpty>
          <ComboboxCollection>
            {(candidate: PrincipalCandidate) => (
              <ComboboxItem key={candidate.id} value={candidate}>
                <span className="flex min-w-0 flex-col">
                  <span className="truncate">{candidate.label ?? candidate.id}</span>
                  <span className="truncate font-mono text-xs text-muted-foreground">{candidate.id}</span>
                </span>
              </ComboboxItem>
            )}
          </ComboboxCollection>
        </ComboboxList>
      </ComboboxContent>
    </Combobox>
  )
}
