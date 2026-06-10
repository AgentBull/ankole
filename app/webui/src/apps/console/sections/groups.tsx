import { RiAddLine, RiDeleteBinLine, RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ConsolePrincipalGroup } from '@/console/service'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { TableCell, TableRow } from '@/uikit/components/table'
import { ErrorAlert, SectionHeader, TableCard } from '../shared'

export function GroupsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const groups = useQuery({
    queryKey: ['console-principal-groups'],
    queryFn: () => unwrap(api.console['principal-groups'].get())
  })
  const [selectedGroupId, setSelectedGroupId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [kind, setKind] = useState<'static' | 'computed'>('static')
  const [description, setDescription] = useState('')
  const [computedCondition, setComputedCondition] = useState('')
  const selectedGroup = groups.data?.groups.find(group => group.id === selectedGroupId)
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['principal-groups'].post({
          name,
          kind,
          description: description.trim() ? description : null,
          computedCondition: kind === 'computed' ? computedCondition : null
        })
      ),
    onSuccess: () => {
      setName('')
      setDescription('')
      setComputedCondition('')
      queryClient.invalidateQueries({ queryKey: ['console-principal-groups'] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['principal-groups']({ id: selectedGroupId ?? '' }).put({
          description: description.trim() ? description : null,
          computedCondition: selectedGroup?.kind === 'computed' ? computedCondition : null
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-principal-groups'] })
  })
  const remove = useMutation({
    mutationFn: (id: string) => unwrap(api.console['principal-groups']({ id }).delete()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-principal-groups'] })
  })

  useEffect(() => {
    if (!selectedGroup) return
    setName(selectedGroup.name)
    setKind(selectedGroup.kind)
    setDescription(selectedGroup.description ?? '')
    setComputedCondition(selectedGroup.computedCondition ?? '')
  }, [selectedGroup])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.groups.title')} description={t('console.groups.description')} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">
            {selectedGroupId ? t('console.groups.edit_title') : t('console.groups.create_title')}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3"
            onSubmit={event => {
              event.preventDefault()
              selectedGroupId ? update.mutate() : create.mutate()
            }}>
            <div className="grid gap-3 md:grid-cols-[1fr_160px_2fr]">
              <Input
                placeholder={t('console.groups.name_placeholder')}
                value={name}
                disabled={Boolean(selectedGroupId)}
                onChange={event => setName(event.target.value)}
              />
              <Select
                value={kind}
                disabled={Boolean(selectedGroupId)}
                onValueChange={value => setKind((value as 'static' | 'computed') ?? 'static')}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="static">{t('console.groups.kind_static')}</SelectItem>
                  <SelectItem value="computed">{t('console.groups.kind_computed')}</SelectItem>
                </SelectContent>
              </Select>
              <Input
                placeholder={t('console.groups.description_placeholder')}
                value={description}
                onChange={event => setDescription(event.target.value)}
              />
            </div>
            <Input
              placeholder={t('console.groups.condition_placeholder')}
              disabled={kind === 'static'}
              value={computedCondition}
              onChange={event => setComputedCondition(event.target.value)}
            />
            <div className="flex flex-wrap items-center gap-2">
              <Button type="submit" disabled={!name.trim() || create.isPending || update.isPending}>
                {create.isPending || update.isPending ? <Spinner /> : selectedGroupId ? <RiSaveLine /> : <RiAddLine />}
                {selectedGroupId ? t('console.groups.save_button') : t('console.groups.create_title')}
              </Button>
              <Button
                type="button"
                variant="ghost"
                onClick={() => {
                  setSelectedGroupId(null)
                  setName('')
                  setKind('static')
                  setDescription('')
                  setComputedCondition('')
                }}>
                {t('console.clear')}
              </Button>
            </div>
          </form>
          <ErrorAlert error={create.error ?? update.error} title={t('console.groups.save_failed')} />
        </CardContent>
      </Card>
      <TableCard
        loading={groups.isPending}
        error={groups.error}
        empty={(groups.data?.groups.length ?? 0) === 0}
        columns={[
          t('console.groups.column_name'),
          t('console.groups.column_kind'),
          t('console.groups.column_built_in'),
          t('console.groups.column_members'),
          t('console.groups.column_description'),
          t('console.actions')
        ]}>
        {(groups.data?.groups ?? []).map((group: ConsolePrincipalGroup) => (
          <TableRow key={group.id}>
            <TableCell className="font-medium">{group.name}</TableCell>
            <TableCell>
              {t(group.kind === 'computed' ? 'console.groups.kind_computed' : 'console.groups.kind_static')}
            </TableCell>
            <TableCell>{group.builtIn ? t('console.yes') : t('console.no')}</TableCell>
            <TableCell>{group.membershipCount}</TableCell>
            <TableCell className="max-w-[280px] truncate">{group.description ?? '-'}</TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button size="sm" variant="outline" onClick={() => setSelectedGroupId(group.id)}>
                  {t('console.edit')}
                </Button>
                <Button
                  variant="ghost"
                  size="icon-xs"
                  disabled={group.builtIn || remove.isPending}
                  onClick={() => {
                    if (window.confirm(t('console.groups.delete_confirm', { name: group.name }))) {
                      remove.mutate(group.id)
                    }
                  }}>
                  <RiDeleteBinLine />
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}
