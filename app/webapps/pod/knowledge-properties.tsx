import { Button, Drawer, DrawerContent, DrawerFooter, DrawerHeader, DrawerTitle, Input, Textarea } from '@ankole/uikit'
import { RiAddLine, RiCodeLine, RiDeleteBinLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { stringify } from 'yaml'
import { KnowledgeDraftModel, parseMetadata, propertySource, type KnowledgeMetadata } from './state/knowledge-draft'

export function KnowledgeProperties({
  metadata,
  draft
}: {
  metadata: KnowledgeMetadata
  draft?: InstanceType<typeof KnowledgeDraftModel>
}) {
  useSignals()
  const { t } = useTranslation()
  const [yaml, setYAML] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const editing = draft?.editing.value ?? false
  const current = editing ? (draft!.parsed.value.metadata ?? metadata) : metadata
  return (
    <section aria-label={t('pod.knowledge.properties')} className="mb-5 border-y border-border py-3">
      <div className="mb-2 flex items-center justify-between gap-2">
        <h2 className="text-xs font-medium text-fg-secondary">{t('pod.knowledge.properties')}</h2>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => {
            setError(null)
            setYAML(stringify(current))
          }}>
          <RiCodeLine aria-hidden className="size-4" /> YAML
        </Button>
      </div>
      {editing ? (
        <div className="space-y-2">
          {draft!.entries.value.map((entry, index) => (
            <div key={index} className="flex items-start gap-2">
              <Input
                aria-label={t('pod.knowledge.property_name')}
                className="w-40 shrink-0"
                value={entry.key}
                onChange={event => draft!.change(index, { key: event.target.value })}
              />
              <Textarea
                aria-label={t('pod.knowledge.property_value', { name: entry.key })}
                className="min-h-8 flex-1 font-mono text-xs"
                rows={Math.min(6, entry.source.split('\n').length)}
                value={entry.source}
                onChange={event => draft!.change(index, { source: event.target.value })}
              />
              <Button
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.knowledge.remove_property', { name: entry.key })}
                onClick={() => draft!.remove(index)}>
                <RiDeleteBinLine aria-hidden className="size-4" />
              </Button>
            </div>
          ))}
          <Button size="sm" variant="ghost" onClick={() => draft!.add()}>
            <RiAddLine aria-hidden className="size-4" />
            {t('pod.knowledge.add_property')}
          </Button>
          {draft!.parsed.value.error && (
            <p role="alert" className="text-sm text-destructive">
              {draft!.parsed.value.error}
            </p>
          )}
        </div>
      ) : (
        <dl className="grid grid-cols-[minmax(6rem,10rem)_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm">
          {Object.entries(metadata).map(([key, value]) => (
            <Property key={key} name={key} value={value} />
          ))}
          {!Object.keys(metadata).length && (
            <div className="col-span-2 text-xs text-fg-tertiary">{t('pod.knowledge.no_properties')}</div>
          )}
        </dl>
      )}
      <Drawer open={yaml !== null} onOpenChange={open => !open && setYAML(null)} swipeDirection="right">
        <DrawerContent className="data-[swipe-axis=x]:[--drawer-content-width:100%] data-[swipe-axis=x]:sm:[--drawer-content-width:40rem] p-5 gap-4">
          <DrawerHeader className="p-0">
            <DrawerTitle>{t('pod.knowledge.properties_yaml')}</DrawerTitle>
          </DrawerHeader>
          <Textarea
            aria-label={t('pod.knowledge.properties_yaml')}
            className="min-h-72 flex-1 font-mono text-sm"
            readOnly={!editing}
            value={yaml ?? ''}
            onChange={event => setYAML(event.target.value)}
            spellCheck={false}
          />
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
          <DrawerFooter className="p-0">
            <Button variant="outline" onClick={() => setYAML(null)}>
              {t('common.close')}
            </Button>
            {editing && (
              <Button
                onClick={() => {
                  try {
                    draft!.replace(parseMetadata(yaml ?? ''))
                    setYAML(null)
                  } catch (error) {
                    setError(error instanceof Error ? error.message : String(error))
                  }
                }}>
                {t('pod.knowledge.apply_properties')}
              </Button>
            )}
          </DrawerFooter>
        </DrawerContent>
      </Drawer>
    </section>
  )
}

function Property({ name, value }: { name: string; value: unknown }) {
  return (
    <>
      <dt className="break-words text-fg-secondary">{name}</dt>
      <dd className="whitespace-pre-wrap break-words">{typeof value === 'string' ? value : propertySource(value)}</dd>
    </>
  )
}
