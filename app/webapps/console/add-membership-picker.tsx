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

/** One addable membership target: a group (id = name) or a principal (id = uid). */
export type MembershipCandidate = {
  id: string
  label?: string | null
}

/**
 * Combobox that adds one membership edge between a principal and a group.
 * The page owns the candidate query and the add mutation; this component owns
 * the input state, text filtering, and the excluded-id subtraction.
 */
export function AddMembershipPicker({
  ariaLabel,
  candidates,
  emptyText,
  error,
  excludedIDs,
  isLoading = false,
  onAdd,
  pending,
  placeholder
}: {
  ariaLabel: string
  candidates: MembershipCandidate[]
  emptyText: string
  /** Candidate-query error, shown in the empty slot instead of `emptyText`. */
  error: unknown
  excludedIDs: ReadonlySet<string>
  /** Candidate query still in flight, shown instead of a false "nothing to add". */
  isLoading?: boolean
  onAdd: (id: string) => void
  pending: boolean
  placeholder: string
}) {
  const { t } = useTranslation()
  const [inputValue, setInputValue] = useState('')
  const available = candidates.filter(candidate => !excludedIDs.has(candidate.id))
  const normalized = inputValue.trim().toLowerCase()
  const visible = normalized
    ? available.filter(candidate => `${candidate.label ?? ''}\n${candidate.id}`.toLowerCase().includes(normalized))
    : available

  return (
    <Combobox<MembershipCandidate>
      items={visible}
      value={null}
      inputValue={inputValue}
      itemToStringLabel={candidate => candidate.label ?? candidate.id}
      itemToStringValue={candidate => candidate.id}
      isItemEqualToValue={(candidate, current) => candidate.id === current.id}
      onInputValueChange={setInputValue}
      onValueChange={candidate => {
        if (candidate) {
          onAdd(candidate.id)
          setInputValue('')
        }
      }}>
      <ComboboxInput aria-label={ariaLabel} placeholder={placeholder} disabled={pending} className="w-full max-w-md" />
      <ComboboxContent>
        <ComboboxList>
          {/* A failed or still-loading candidate fetch must not read as "nothing left to add". */}
          <ComboboxEmpty>
            {error ? requestErrorMessage(error) : isLoading ? t('common.loading') : emptyText}
          </ComboboxEmpty>
          <ComboboxCollection>
            {(candidate: MembershipCandidate) => (
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
