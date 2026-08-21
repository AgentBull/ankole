import { Skeleton } from '@ankole/uikit'
import { lazy, Suspense, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { JSONField, LabeledField } from './console-form'
import { SearchField } from './console-list-page'
import { parseJSONObjectDraft } from './state/json-editor'

const JSONObjectEditor = lazy(() => import('./json-object-editor'))

export function JSONObjectField({
  error,
  label,
  name,
  onChange,
  value
}: {
  error?: string
  label: string
  name: string
  onChange: (value: string) => void
  value: string
}) {
  const { t } = useTranslation()
  const [search, setSearch] = useState('')
  const data = parseJSONObjectDraft(value)

  if (!data) {
    return (
      <JSONField
        description={t('console.settings.json_object_hint')}
        error={error}
        label={label}
        value={value}
        minRows={10}
        onChange={onChange}
      />
    )
  }

  return (
    <LabeledField label={label} description={t('console.settings.json_object_hint')} error={error}>
      <div className="grid gap-3">
        <SearchField
          label={t('console.settings.json_search')}
          placeholder={t('console.settings.json_search_placeholder')}
          value={search}
          onChange={setSearch}
        />
        <div className="max-h-[55dvh] overflow-auto">
          <Suspense fallback={<Skeleton className="h-48 w-full" />}>
            <JSONObjectEditor data={data} name={name} search={search} onChange={onChange} />
          </Suspense>
        </div>
      </div>
    </LabeledField>
  )
}
