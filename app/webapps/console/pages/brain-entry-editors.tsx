import {
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Textarea
} from '@ankole/uikit'
import { RiAddLine, RiDeleteBin6Line, RiLinkM } from '@remixicon/react'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { BrainEntry, BrainEntryBlock, BrainEntryOperation, BrainEntryRelation } from '../api/generated/types.gen'
import { formatConsoleDate } from '../console-primitives'
import { LabeledField } from '../console-shell'
import type { PropertyDraft } from '../state/brain-editor-model'

export function MetadataEditor({
  name,
  type,
  summary,
  aliases,
  propertyDrafts,
  onNameChange,
  onTypeChange,
  onSummaryChange,
  onAliasesChange,
  onPropertyDraftsChange
}: {
  name: string
  type: string
  summary: string
  aliases: string[]
  propertyDrafts: PropertyDraft[]
  onNameChange: (value: string) => void
  onTypeChange: (value: string) => void
  onSummaryChange: (value: string) => void
  onAliasesChange: (value: string[]) => void
  onPropertyDraftsChange: (value: PropertyDraft[]) => void
}) {
  const { t } = useTranslation()

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('console.brain.metadata')}</CardTitle>
        <CardDescription>{t('console.brain.metadata_description')}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-5">
        <div className="grid gap-4 md:grid-cols-2">
          <LabeledField label={t('console.brain.name')}>
            <Input value={name} onChange={event => onNameChange(event.target.value)} />
          </LabeledField>
          <LabeledField label={t('console.brain.type')}>
            <Input value={type} onChange={event => onTypeChange(event.target.value)} />
          </LabeledField>
        </div>
        <LabeledField label={t('console.brain.summary')}>
          <Textarea value={summary} onChange={event => onSummaryChange(event.target.value)} />
        </LabeledField>
        <StructuredAliases aliases={aliases} onChange={onAliasesChange} />
        <StructuredProperties drafts={propertyDrafts} onChange={onPropertyDraftsChange} />
      </CardContent>
    </Card>
  )
}

function StructuredAliases({ aliases, onChange }: { aliases: string[]; onChange: (aliases: string[]) => void }) {
  const { t } = useTranslation()
  return (
    <section className="grid gap-2">
      <div className="flex items-center justify-between gap-3">
        <h4 className="text-sm font-medium">{t('console.brain.aliases')}</h4>
        <Button type="button" size="xs" variant="outline" onClick={() => onChange([...aliases, ''])}>
          <RiAddLine />
          {t('common.new')}
        </Button>
      </div>
      {aliases.length === 0 ? <p className="text-sm text-muted-foreground">{t('console.brain.no_aliases')}</p> : null}
      {aliases.map((alias, index) => (
        <div key={index} className="flex gap-2">
          <Input
            value={alias}
            onChange={event =>
              onChange(aliases.map((value, itemIndex) => (itemIndex === index ? event.target.value : value)))
            }
          />
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            aria-label={t('common.delete')}
            onClick={() => onChange(aliases.filter((_value, itemIndex) => itemIndex !== index))}>
            <RiDeleteBin6Line />
          </Button>
        </div>
      ))}
    </section>
  )
}

function StructuredProperties({
  drafts,
  onChange
}: {
  drafts: PropertyDraft[]
  onChange: (value: PropertyDraft[]) => void
}) {
  const { t } = useTranslation()
  return (
    <section className="grid gap-2">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h4 className="text-sm font-medium">{t('console.brain.properties')}</h4>
          <p className="text-xs text-muted-foreground">{t('console.brain.properties_hint')}</p>
        </div>
        <Button
          type="button"
          size="xs"
          variant="outline"
          onClick={() => onChange([...drafts, { key: '', value: 'null' }])}>
          <RiAddLine />
          {t('common.new')}
        </Button>
      </div>
      {drafts.length === 0 ? <p className="text-sm text-muted-foreground">{t('console.brain.no_properties')}</p> : null}
      {drafts.map((draft, index) => (
        <div
          key={index}
          className="grid gap-2 border border-border p-3 md:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_auto]">
          <Input
            aria-label={t('console.brain.property_key')}
            placeholder={t('console.brain.property_key')}
            value={draft.key}
            onChange={event =>
              onChange(
                drafts.map((value, itemIndex) => (itemIndex === index ? { ...value, key: event.target.value } : value))
              )
            }
          />
          <Textarea
            aria-label={t('console.brain.property_value')}
            className="min-h-20 font-mono text-xs"
            value={draft.value}
            onChange={event =>
              onChange(
                drafts.map((value, itemIndex) =>
                  itemIndex === index ? { ...value, value: event.target.value } : value
                )
              )
            }
          />
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            aria-label={t('common.delete')}
            onClick={() => onChange(drafts.filter((_value, itemIndex) => itemIndex !== index))}>
            <RiDeleteBin6Line />
          </Button>
        </div>
      ))}
    </section>
  )
}

export function BlocksEditor({
  blocks,
  entry,
  pending,
  onApply
}: {
  blocks: BrainEntryBlock[]
  entry: BrainEntry
  pending: boolean
  onApply: (operations: BrainEntryOperation[], onSuccess?: () => void, reason?: string) => void
}) {
  const { t } = useTranslation()
  const [newBody, setNewBody] = useState('')
  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('console.brain.blocks')}</CardTitle>
        <CardDescription>{t('console.brain.blocks_description')}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        {blocks.map(block => (
          <BlockEditor key={`${block.id}:${block.lock_version}`} block={block} pending={pending} onApply={onApply} />
        ))}
        <div className="grid gap-2 border border-dashed border-border p-4">
          <Textarea
            className="min-h-32"
            placeholder={t('console.brain.new_block_placeholder')}
            value={newBody}
            onChange={event => setNewBody(event.target.value)}
          />
          <Button
            type="button"
            size="sm"
            className="w-fit"
            disabled={pending || !newBody.trim()}
            onClick={() => {
              onApply(
                [
                  {
                    operation: 'append_block',
                    entry_id: entry.id,
                    body: newBody.trim(),
                    expected_entry_lock_version: entry.lock_version
                  }
                ],
                () => setNewBody('')
              )
            }}>
            <RiAddLine />
            {t('console.brain.add_block')}
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}

function BlockEditor({
  block,
  pending,
  onApply
}: {
  block: BrainEntryBlock
  pending: boolean
  onApply: (operations: BrainEntryOperation[], onSuccess?: () => void, reason?: string) => void
}) {
  const { t } = useTranslation()
  const [body, setBody] = useState(block.body)
  const [reason, setReason] = useState('')
  const [retireOpen, setRetireOpen] = useState(false)
  return (
    <article className="grid gap-3 border border-border p-4">
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant="outline">#{block.position + 1}</Badge>
          <Badge variant="secondary">{block.author_kind}</Badge>
          <span>{block.author_uid || '—'}</span>
          <span>{formatConsoleDate(block.updated_at)}</span>
        </div>
        <Badge variant={block.embedding_state === 'failed' ? 'destructive' : 'outline'}>{block.embedding_state}</Badge>
      </div>
      <Textarea className="min-h-40" value={body} onChange={event => setBody(event.target.value)} />
      <LabeledField label={t('console.brain.correction_reason')} description={t('console.brain.reason_optional')}>
        <Input value={reason} onChange={event => setReason(event.target.value)} />
      </LabeledField>
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          size="sm"
          disabled={pending || !body.trim() || body === block.body}
          onClick={() =>
            onApply(
              [
                {
                  operation: 'edit_block',
                  entry_id: block.entry_id,
                  block_id: block.id,
                  body: body.trim(),
                  expected_block_lock_version: block.lock_version
                }
              ],
              () => setReason(''),
              reason
            )
          }>
          {t('console.brain.correct_block')}
        </Button>
        <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={() => setRetireOpen(true)}>
          <RiDeleteBin6Line />
          {t('console.brain.no_longer_valid')}
        </Button>
      </div>
      <Dialog open={retireOpen} onOpenChange={setRetireOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('console.brain.retire_block_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.retire_block_description')}</DialogDescription>
          </DialogHeader>
          <LabeledField label={t('console.brain.correction_reason')} description={t('console.brain.reason_optional')}>
            <Input value={reason} onChange={event => setReason(event.target.value)} />
          </LabeledField>
          <DialogFooter>
            <DialogClose render={<Button type="button" variant="outline" />}>{t('common.cancel')}</DialogClose>
            <Button
              type="button"
              variant="destructive"
              disabled={pending}
              onClick={() =>
                onApply(
                  [
                    {
                      operation: 'delete_block',
                      entry_id: block.entry_id,
                      block_id: block.id,
                      expected_block_lock_version: block.lock_version
                    }
                  ],
                  () => {
                    setRetireOpen(false)
                    setReason('')
                  },
                  reason
                )
              }>
              {t('console.brain.no_longer_valid')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </article>
  )
}

export function RelationsEditor({
  relations,
  backlinks,
  candidates,
  entry,
  pending,
  onApply
}: {
  relations: BrainEntryRelation[]
  backlinks: BrainEntryRelation[]
  candidates: BrainEntry[]
  entry: BrainEntry
  pending: boolean
  onApply: (operations: BrainEntryOperation[], onSuccess?: () => void, reason?: string) => void
}) {
  const { t } = useTranslation()
  const [predicate, setPredicate] = useState('')
  const [targetEntryID, setTargetEntryID] = useState('')
  const allowedTargets = candidates.filter(candidate => {
    if (candidate.id === entry.id) return false
    return entry.store_key === 'shared'
      ? candidate.store_key === 'shared'
      : candidate.store_key === 'shared' || candidate.store_key === entry.store_key
  })
  const targetListID = `brain-relation-targets-${entry.id}`
  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('console.brain.relations')}</CardTitle>
        <CardDescription>{t('console.brain.relations_description')}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-5">
        <div className="grid gap-2">
          {relations.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('console.brain.no_relations')}</p>
          ) : null}
          {relations.map(relation => (
            <RelationRow
              key={relation.id}
              relation={relation}
              removable
              pending={pending}
              onRemove={() =>
                onApply([
                  {
                    operation: 'remove_relation',
                    entry_id: entry.id,
                    relation_id: relation.id,
                    expected_entry_lock_version: entry.lock_version
                  }
                ])
              }
            />
          ))}
        </div>
        <div className="grid gap-3 border border-dashed border-border p-4 md:grid-cols-[1fr_1.5fr_auto]">
          <Input
            placeholder={t('console.brain.predicate')}
            value={predicate}
            onChange={event => setPredicate(event.target.value)}
          />
          <Input
            list={targetListID}
            placeholder={t('console.brain.target_entry_id')}
            value={targetEntryID}
            onChange={event => setTargetEntryID(event.target.value)}
          />
          <datalist id={targetListID}>
            {allowedTargets.map(candidate => (
              <option key={candidate.id} value={candidate.id}>
                {candidate.name} · {candidate.type} · {candidate.store_key}
              </option>
            ))}
          </datalist>
          <Button
            type="button"
            size="sm"
            disabled={pending || !predicate.trim() || !targetEntryID.trim()}
            onClick={() => {
              onApply(
                [
                  {
                    operation: 'add_relation',
                    entry_id: entry.id,
                    target_entry_id: targetEntryID.trim(),
                    predicate: predicate.trim(),
                    expected_entry_lock_version: entry.lock_version
                  }
                ],
                () => {
                  setPredicate('')
                  setTargetEntryID('')
                }
              )
            }}>
            <RiLinkM />
            {t('console.brain.add_relation')}
          </Button>
        </div>
        <section className="grid gap-2">
          <h4 className="text-sm font-medium">{t('console.brain.backlinks')}</h4>
          {backlinks.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('console.brain.no_backlinks')}</p>
          ) : null}
          {backlinks.map(relation => (
            <RelationRow key={relation.id} relation={relation} pending={pending} />
          ))}
        </section>
      </CardContent>
    </Card>
  )
}

function RelationRow({
  relation,
  removable = false,
  pending,
  onRemove
}: {
  relation: BrainEntryRelation
  removable?: boolean
  pending: boolean
  onRemove?: () => void
}) {
  const { t } = useTranslation()
  return (
    <div className="flex flex-wrap items-center gap-2 border border-border px-3 py-2 text-sm">
      <span className="font-medium">{relation.source_name || relation.source_entry_id}</span>
      <Badge variant="outline">{relation.predicate}</Badge>
      <span className="font-medium">{relation.target_name || relation.target_entry_id}</span>
      {removable ? (
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          disabled={pending}
          className="ml-auto"
          aria-label={t('common.delete')}
          onClick={onRemove}>
          <RiDeleteBin6Line />
        </Button>
      ) : null}
    </div>
  )
}
