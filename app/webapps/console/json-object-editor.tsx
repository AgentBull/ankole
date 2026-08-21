import {
  RiAddLine,
  RiArrowRightSLine,
  RiCheckLine,
  RiCloseLine,
  RiDeleteBinLine,
  RiEditLine,
  RiFileCopyLine
} from '@remixicon/react'
import { JsonEditor, type IconReplacements, type LocalisedStrings, type Theme } from 'json-edit-react'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { serializeJSONObjectDraft } from './state/json-editor'

/**
 * The json-edit-react tree editor behind `JSONObjectField`. It lives in its
 * own module as the target of a dynamic import, so the editor library loads
 * only when a JSON object setting is actually opened.
 */
export default function JSONObjectEditor({
  data,
  name,
  onChange,
  search
}: {
  data: Record<string, unknown>
  name: string
  onChange: (value: string) => void
  search: string
}) {
  const { t } = useTranslation()
  const translations = useMemo<Partial<LocalisedStrings>>(
    () => ({
      ITEM_SINGLE: t('console.settings.json_item'),
      ITEMS_MULTIPLE: t('console.settings.json_items'),
      KEY_NEW: t('console.settings.json_new_key'),
      KEY_SELECT: t('console.settings.json_select_key'),
      NO_KEY_OPTIONS: t('console.settings.json_no_keys'),
      ERROR_KEY_EXISTS: t('console.settings.json_key_exists'),
      ERROR_INVALID_JSON: t('console.settings.json_invalid'),
      ERROR_UPDATE: t('console.settings.json_update_failed'),
      ERROR_DELETE: t('console.settings.json_delete_failed'),
      ERROR_ADD: t('console.settings.json_add_failed'),
      DEFAULT_STRING: t('console.settings.json_default_string'),
      DEFAULT_NEW_KEY: t('console.settings.json_default_key'),
      SHOW_LESS: t('console.settings.json_show_less'),
      EMPTY_STRING: t('console.settings.json_empty_string'),
      TOOLTIP_COPY: t('console.settings.json_copy'),
      TOOLTIP_EDIT: t('console.settings.json_edit'),
      TOOLTIP_DELETE: t('console.settings.json_delete'),
      TOOLTIP_ADD: t('console.settings.json_add')
    }),
    [t]
  )

  return (
    <JsonEditor
      data={data}
      setData={nextData => {
        const nextValue = serializeJSONObjectDraft(nextData)
        if (nextValue !== undefined) onChange(nextValue)
      }}
      rootName={name}
      theme={THEME}
      icons={ICONS}
      translations={translations}
      className="ankole-json-editor min-w-full"
      minWidth="100%"
      maxWidth="100%"
      rootFontSize="13px"
      indent={2}
      defaultValue={null}
      enableClipboard={false}
      restrictDrag
      searchText={search}
      searchFilter="all"
      showIconTooltips
      showCollectionCount="when-closed"
      showStringQuotes
      onUpdate={({ newData }) =>
        serializeJSONObjectDraft(newData) === undefined ? t('console.settings.json_object_required') : undefined
      }
    />
  )
}

const ICON_CLASS =
  'inline-flex size-6 items-center justify-center border border-transparent text-muted-foreground transition-colors hover:bg-muted hover:text-link'
const DANGER_ICON_CLASS =
  'inline-flex size-6 items-center justify-center border border-transparent text-muted-foreground transition-colors hover:bg-muted hover:text-destructive'

const ICONS: IconReplacements = {
  add: (
    <span className={ICON_CLASS}>
      <RiAddLine className="size-4" />
    </span>
  ),
  edit: (
    <span className={ICON_CLASS}>
      <RiEditLine className="size-4" />
    </span>
  ),
  delete: (
    <span className={DANGER_ICON_CLASS}>
      <RiDeleteBinLine className="size-4" />
    </span>
  ),
  copy: (
    <span className={ICON_CLASS}>
      <RiFileCopyLine className="size-4" />
    </span>
  ),
  ok: (
    <span className={ICON_CLASS}>
      <RiCheckLine className="size-4" />
    </span>
  ),
  cancel: (
    <span className={DANGER_ICON_CLASS}>
      <RiCloseLine className="size-4" />
    </span>
  ),
  chevron: (
    <span className="inline-flex size-4 items-center justify-center text-muted-foreground">
      <RiArrowRightSLine className="size-4" />
    </span>
  )
}

const THEME: Theme = {
  displayName: 'Ankole',
  styles: {
    container: {
      width: '100%',
      backgroundColor: 'var(--field)',
      border: '1px solid var(--input)',
      borderRadius: '0',
      color: 'var(--foreground)',
      fontFamily: 'var(--font-family-mono)',
      fontSize: '0.8125rem',
      lineHeight: '1.25rem',
      padding: '0.75rem 0.75rem 0.75rem 1.5rem'
    },
    collection: { backgroundColor: 'transparent' },
    collectionInner: { backgroundColor: 'transparent' },
    collectionElement: { backgroundColor: 'transparent' },
    dropZone: 'var(--border)',
    property: 'var(--ankole-json-key)',
    bracket: 'var(--ankole-json-punctuation)',
    itemCount: 'var(--ankole-json-punctuation)',
    string: 'var(--ankole-json-string)',
    number: 'var(--ankole-json-number)',
    boolean: 'var(--ankole-json-boolean)',
    null: 'var(--ankole-json-null)',
    input: {
      backgroundColor: 'var(--background)',
      border: '1px solid var(--ring)',
      color: 'var(--foreground)',
      padding: '0.125rem 0.375rem'
    },
    inputHighlight: 'var(--muted)',
    error: 'var(--destructive)',
    iconCollection: 'var(--muted-foreground)',
    iconEdit: 'var(--primary)',
    iconDelete: 'var(--destructive)',
    iconAdd: 'var(--primary)',
    iconCopy: 'var(--muted-foreground)',
    iconOk: 'var(--ankole-json-boolean)',
    iconCancel: 'var(--destructive)'
  }
}
