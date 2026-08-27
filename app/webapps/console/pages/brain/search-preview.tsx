import {
  Badge,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@ankole/uikit'
import { RiCloseLine, RiLoaderLine, RiSearchEyeLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebBrainControllerSearchPreviewMutation,
  ankoleWebPrincipalControllerIndexOptions
} from '../../api/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../../common/error-block'
import { AddMembershipPicker } from '../../add-membership-picker'
import { LabeledField } from '../../console-form'
import { PageHeader, PageStack } from '../../console-page'
import { SinglePrincipalPicker } from '../../principal-picker'
import { BrainSubNav } from './brain-nav'

/** Runs recall as any Principal to diagnose knowledge boundaries and disclosure behavior. */
export function BrainSearchPreviewPage() {
  const { t } = useTranslation()
  const [principalUID, setPrincipalUID] = useState('')
  const [query, setQuery] = useState('')
  const [mode, setMode] = useState<'strict' | 'relaxed'>('relaxed')
  const [askerUID, setAskerUID] = useState('')
  const [presentUIDs, setPresentUIDs] = useState<string[]>([])

  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const candidates = (principals.data?.principals ?? []).map(principal => ({
    id: principal.uid,
    label: principal.display_name
  }))

  const preview = useMutation(ankoleWebBrainControllerSearchPreviewMutation())
  const runPreview = () =>
    preview.mutate({
      body: {
        principal_uid: principalUID,
        query: query.trim(),
        disclosure_mode: mode,
        ...(askerUID ? { asker_uid: askerUID } : {}),
        ...(presentUIDs.length > 0 ? { present_uids: presentUIDs } : {})
      }
    })
  const result = preview.data?.result

  return (
    <PageStack>
      <PageHeader
        title={t('console.brain.search_preview_title')}
        description={t('console.brain.search_preview_description')}
      />
      <BrainSubNav />

      <form
        className="grid gap-5 border border-border bg-card p-5"
        onSubmit={event => {
          event.preventDefault()
          if (principalUID && query.trim()) runPreview()
        }}>
        <div className="grid gap-5 md:grid-cols-2">
          <LabeledField label={t('console.brain.recall_principal')} required>
            <SinglePrincipalPicker
              ariaLabel={t('console.brain.recall_principal')}
              candidates={candidates}
              error={principals.error}
              isLoading={principals.isLoading}
              placeholder={t('console.brain.select_principal')}
              value={principalUID}
              onChange={setPrincipalUID}
            />
          </LabeledField>
          <LabeledField
            label={t('console.brain.disclosure_mode')}
            description={t('console.brain.disclosure_mode_hint')}>
            <Select
              value={mode}
              onValueChange={value => {
                if (value === 'strict' || value === 'relaxed') setMode(value)
              }}>
              <SelectTrigger aria-label={t('console.brain.disclosure_mode')} className="w-full">
                <SelectValue>{value => t(`console.brain.disclosure_mode_${String(value)}`)}</SelectValue>
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="strict">{t('console.brain.disclosure_mode_strict')}</SelectItem>
                <SelectItem value="relaxed">{t('console.brain.disclosure_mode_relaxed')}</SelectItem>
              </SelectContent>
            </Select>
          </LabeledField>
          <LabeledField label={t('console.brain.asker')} description={t('console.brain.asker_hint')}>
            <SinglePrincipalPicker
              ariaLabel={t('console.brain.asker')}
              candidates={candidates}
              error={principals.error}
              isLoading={principals.isLoading}
              placeholder={t('console.brain.select_principal')}
              value={askerUID}
              onChange={setAskerUID}
            />
          </LabeledField>
          <LabeledField
            label={t('console.brain.present_members')}
            description={t('console.brain.present_members_hint')}>
            <div className="grid gap-2">
              <AddMembershipPicker
                ariaLabel={t('console.brain.present_members')}
                candidates={candidates}
                emptyText={t('common.select_empty')}
                error={principals.error}
                excludedIDs={new Set(presentUIDs)}
                isLoading={principals.isLoading}
                pending={false}
                placeholder={t('console.brain.add_present_member')}
                onAdd={uid => setPresentUIDs(current => [...current, uid])}
              />
              {presentUIDs.length > 0 ? (
                <div className="flex flex-wrap gap-1.5">
                  {presentUIDs.map(uid => (
                    <Badge key={uid} variant="secondary">
                      <span className="font-mono">{uid}</span>
                      <button
                        aria-label={t('console.brain.remove_present_member', { uid })}
                        className="ml-1 inline-flex"
                        type="button"
                        onClick={() => setPresentUIDs(current => current.filter(item => item !== uid))}>
                        <RiCloseLine className="size-3" />
                      </button>
                    </Badge>
                  ))}
                </div>
              ) : null}
            </div>
          </LabeledField>
        </div>
        <div className="flex items-end gap-3">
          <div className="min-w-0 flex-1">
            <LabeledField label={t('console.brain.recall_query')} required>
              <Input required value={query} onChange={event => setQuery(event.target.value)} />
            </LabeledField>
          </div>
          <Button disabled={preview.isPending || !principalUID || !query.trim()} type="submit">
            {preview.isPending ? (
              <RiLoaderLine className="animate-spin" data-icon="inline-start" />
            ) : (
              <RiSearchEyeLine data-icon="inline-start" />
            )}
            {t('console.brain.run_recall')}
          </Button>
        </div>
      </form>

      <ErrorBlock error={preview.error} />

      {result ? (
        <div className="grid gap-6">
          <p className="text-xs text-muted-foreground">
            {t('console.brain.recall_stats', {
              claims: result.claims.length,
              chunks: result.chunks.length,
              sanitized: result.sanitized_count
            })}
          </p>

          <section className="grid gap-3">
            <h3 className="text-sm font-semibold">{t('console.brain.recall_claims')}</h3>
            {result.claims.length === 0 ? (
              <p className="border border-dashed border-border px-4 py-4 text-xs text-muted-foreground">
                {t('console.brain.no_rows')}
              </p>
            ) : (
              <Table containerClassName="border border-border bg-card">
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('console.brain.claim')}</TableHead>
                    <TableHead>{t('console.brain.type')}</TableHead>
                    <TableHead>{t('console.brain.holder')}</TableHead>
                    <TableHead>{t('console.brain.object')}</TableHead>
                    <TableHead>{t('console.brain.scope')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {result.claims.map(claim => (
                    <TableRow key={claim.id}>
                      <TableCell className="max-w-[420px] whitespace-normal text-xs">{claim.claim}</TableCell>
                      <TableCell>
                        <Badge variant={claim.claim_type === 'fact' ? 'secondary' : 'info'}>
                          {claim.claim_type}
                          {claim.kind ? ` · ${claim.kind}` : ''}
                        </Badge>
                      </TableCell>
                      <TableCell className="font-mono text-xs">{claim.holder ?? '—'}</TableCell>
                      <TableCell className="font-mono text-xs">{claim.object_slug ?? '—'}</TableCell>
                      <TableCell className="font-mono text-xs">{claim.audience_scope}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </section>

          <section className="grid gap-3">
            <h3 className="text-sm font-semibold">{t('console.brain.recall_chunks')}</h3>
            {result.chunks.length === 0 ? (
              <p className="border border-dashed border-border px-4 py-4 text-xs text-muted-foreground">
                {t('console.brain.no_rows')}
              </p>
            ) : (
              <div className="grid gap-3">
                {result.chunks.map((chunk, index) => (
                  <article
                    key={`${chunk.object_slug}-${chunk.chunk_index}-${index}`}
                    className="grid gap-2 border border-border bg-card p-4">
                    <div className="flex flex-wrap items-center gap-2 text-xs">
                      <span className="font-semibold">{chunk.title}</span>
                      <span className="font-mono text-muted-foreground">{chunk.object_slug}</span>
                      <Badge variant="outline">{chunk.type}</Badge>
                      <Badge variant="outline">#{chunk.chunk_index}</Badge>
                      <span className="font-mono text-muted-foreground">{chunk.audience_scope}</span>
                    </div>
                    <p className="text-xs whitespace-pre-wrap leading-5 text-muted-foreground">{chunk.text}</p>
                  </article>
                ))}
              </div>
            )}
          </section>
        </div>
      ) : null}
    </PageStack>
  )
}
