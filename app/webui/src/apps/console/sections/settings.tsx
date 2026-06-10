import { RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { ErrorAlert, SectionHeader, SkeletonRows } from '../shared'

export function SettingsPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const settings = useQuery({
    queryKey: ['console-settings'],
    queryFn: () => unwrap(api.console.settings.get())
  })
  const [defaultLocale, setDefaultLocale] = useState('')
  const [timezone, setTimezone] = useState('')
  const [publicBaseUrl, setPublicBaseUrl] = useState('')

  const data = settings.data?.settings
  useEffect(() => {
    if (!data) return
    setDefaultLocale(data.defaultLocale)
    setTimezone(data.timezone ?? '')
    setPublicBaseUrl(data.publicBaseUrl ?? '')
  }, [data])

  const save = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.settings.put({
          defaultLocale,
          timezone: timezone.trim() ? timezone.trim() : undefined,
          publicBaseUrl: publicBaseUrl.trim() ? publicBaseUrl.trim() : undefined
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-settings'] })
  })

  const timezoneOptions = useMemo(
    () => (typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : []),
    []
  )

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.settings.title')} description={t('console.settings.description')} />
      {settings.isPending ? (
        <SkeletonRows rows={3} />
      ) : settings.error ? (
        <ErrorAlert error={settings.error} title={t('console.settings.load_failed')} />
      ) : (
        <Card size="sm">
          <CardHeader>
            <CardTitle className="text-base">{t('console.settings.card_title')}</CardTitle>
          </CardHeader>
          <CardContent>
            <form
              className="grid gap-4"
              onSubmit={event => {
                event.preventDefault()
                save.mutate()
              }}>
              <FieldGroup className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                <Field>
                  <FieldLabel>{t('console.settings.default_locale_label')}</FieldLabel>
                  <Select value={defaultLocale} onValueChange={value => setDefaultLocale(value ?? '')}>
                    <SelectTrigger className="w-full">
                      <SelectValue placeholder={t('console.settings.select_locale')} />
                    </SelectTrigger>
                    <SelectContent>
                      {(data?.availableLocales ?? []).map(option => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label} ({option.value})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FieldDescription>
                    <code>i18n.default_locale</code> — {t('console.settings.default_locale_description')}
                  </FieldDescription>
                </Field>
                <Field>
                  <FieldLabel>{t('console.settings.timezone_label')}</FieldLabel>
                  <Input
                    list="console-settings-timezones"
                    placeholder={data?.effectiveTimezone}
                    value={timezone}
                    onChange={event => setTimezone(event.target.value)}
                  />
                  <datalist id="console-settings-timezones">
                    {timezoneOptions.map(zone => (
                      <option key={zone} value={zone} />
                    ))}
                  </datalist>
                  <FieldDescription>
                    <code>system.timezone</code> — {t('console.settings.timezone_description')}{' '}
                    {t('console.settings.timezone_effective')}{' '}
                    <span className="font-mono">{data?.effectiveTimezone || t('console.settings.unknown')}</span>.
                  </FieldDescription>
                </Field>
                <Field>
                  <FieldLabel>{t('console.settings.public_base_url_label')}</FieldLabel>
                  <Input
                    type="url"
                    placeholder="https://bullx.example.com"
                    value={publicBaseUrl}
                    onChange={event => setPublicBaseUrl(event.target.value)}
                  />
                  <FieldDescription>
                    <code>admin_auth.public_base_url</code> — {t('console.settings.public_base_url_description')}
                  </FieldDescription>
                </Field>
              </FieldGroup>
              <div className="flex items-center gap-2">
                <Button type="submit" disabled={!defaultLocale || save.isPending}>
                  {save.isPending ? <Spinner /> : <RiSaveLine />}
                  {t('console.settings.save_button')}
                </Button>
                {save.isSuccess && !save.isPending ? (
                  <span className="text-sm text-muted-foreground">{t('console.settings.saved_note')}</span>
                ) : null}
              </div>
            </form>
            <ErrorAlert error={save.error} title={t('console.settings.save_failed')} />
          </CardContent>
        </Card>
      )}
    </div>
  )
}
