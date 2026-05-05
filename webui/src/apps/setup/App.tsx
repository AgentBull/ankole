import {
  RiAddLine,
  RiArrowDownSLine,
  RiArrowLeftLine,
  RiArrowRightSLine,
  RiCheckboxCircleLine,
  RiCloseLine,
  RiDeleteBinLine,
  RiEditLine,
  RiExternalLinkLine,
  RiFileCopyLine,
  RiKeyLine,
  RiPlugLine,
  RiRefreshLine,
  RiSaveLine,
} from "@remixicon/react"
import React from "react"
import { useTranslation } from "react-i18next"
import { Badge } from "@/uikit/components/badge"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardFooter, CardHeader, CardTitle } from "@/uikit/components/card"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/uikit/components/collapsible"
import { Input } from "@/uikit/components/input"
import { Label } from "@/uikit/components/label"
import { Select, SelectContent, SelectItem, SelectTrigger } from "@/uikit/components/select"
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/uikit/components/sheet"
import { Switch } from "@/uikit/components/switch"
import SetupLayout from "./Layout"

type Translate = (key: string, options?: { values?: Record<string, unknown>; defaultValue?: string }) => string

type SecretField = "app_secret" | "bot_token" | "client_secret" | "transport.secret_token"
type SecretStatus = "missing" | "stored"

interface AdapterAdvanced {
  dedupe_ttl_ms: number
  message_context_ttl_ms?: number
  card_action_dedupe_ttl_ms?: number
  inline_media_max_bytes?: number
  stream_update_interval_ms: number
  thread_ownership_cache_ttl_ms?: number
  stream_chunk_soft_limit?: number
  application_commands_sync_policy?: string
  commands_sync_policy?: string
  poll_timeout_s?: number
  poll_limit?: number
  poll_retry_max?: number
  flood_wait_max_ms?: number
}

interface AdapterCredentials {
  app_id?: string
  app_secret?: string
  application_id?: string
  bot_token?: string
  client_secret?: string
  bot_username?: string
}

interface AdapterAuthnExternalOrgMembers {
  enabled: boolean
  tenant_key: string
}

interface AdapterAuthn {
  external_org_members: AdapterAuthnExternalOrgMembers
}

interface AdapterEntry {
  id: string
  adapter: string
  channel_id: string
  enabled: boolean
  web_login_disabled: boolean
  domain: string
  authn: AdapterAuthn
  auto_thread?: {
    enabled: boolean
    auto_archive_duration_minutes: number
    no_thread_channel_ids: string[]
  }
  transport?: {
    mode: string
    set_webhook: boolean
    secret_token: string
  }
  attention?: {
    allowed_channel_ids?: string[]
    ignored_channel_ids?: string[]
    allowed_chat_ids?: string[]
    ignored_chat_ids?: string[]
    ignored_thread_ids?: string[]
    require_mention: boolean
    free_response_chat_ids?: string[]
  }
  credentials: AdapterCredentials
  advanced: AdapterAdvanced
  secret_status: Partial<Record<SecretField, SecretStatus>>
  config_doc_url?: string
}

interface AdapterAuthnPolicy {
  type: string
}

interface AdapterCatalogEntry {
  adapter: string
  label?: string
  default_entry?: Partial<AdapterEntry>
  authn_policies?: AdapterAuthnPolicy[]
  config_doc_url?: string
  fields?: AdapterFieldDescriptor[]
}

interface AdapterFieldDescriptor {
  path: string[]
  type: string
  secret?: boolean
}

interface AdapterError {
  field?: string
  message: string
  kind?: string
  details?: { field?: string; field_path?: string }
}

interface CheckSuccess {
  status: "success"
  token?: string
  result?: unknown
}

interface CheckFailure {
  status: "error"
  errors: AdapterError[]
}

type CheckResult = CheckSuccess | CheckFailure
type ChecksMap = Record<string, CheckResult | undefined>

interface PostJsonResponse {
  ok?: boolean
  errors?: AdapterError[]
  redirect_to?: string
  connectivity_token?: string
  result?: unknown
  adapter?: AdapterEntry
  value?: string
}

const FEISHU_ADVANCED_FIELDS: Array<keyof AdapterAdvanced> = [
  "dedupe_ttl_ms",
  "message_context_ttl_ms",
  "card_action_dedupe_ttl_ms",
  "inline_media_max_bytes",
  "stream_update_interval_ms",
]
const DISCORD_ADVANCED_FIELDS: Array<keyof AdapterAdvanced> = [
  "dedupe_ttl_ms",
  "thread_ownership_cache_ttl_ms",
  "stream_update_interval_ms",
  "stream_chunk_soft_limit",
]
const TELEGRAM_ADVANCED_FIELDS: Array<keyof AdapterAdvanced> = [
  "dedupe_ttl_ms",
  "poll_timeout_s",
  "poll_limit",
  "poll_retry_max",
  "flood_wait_max_ms",
  "stream_update_interval_ms",
  "stream_chunk_soft_limit",
]
const DISCORD_SYNC_POLICIES = ["safe", "off"] as const
const TELEGRAM_SYNC_POLICIES = ["replace", "off"] as const

const FALLBACK_ENTRY: AdapterEntry = {
  id: "feishu:",
  adapter: "feishu",
  channel_id: "",
  enabled: true,
  web_login_disabled: false,
  domain: "feishu",
  authn: {
    external_org_members: {
      enabled: false,
      tenant_key: "",
    },
  },
  credentials: {
    app_id: "",
    app_secret: "",
    application_id: "",
    bot_token: "",
    client_secret: "",
    bot_username: "",
  },
  attention: {
    allowed_channel_ids: [],
    ignored_channel_ids: [],
    allowed_chat_ids: [],
    ignored_chat_ids: [],
    ignored_thread_ids: [],
    require_mention: true,
    free_response_chat_ids: [],
  },
  auto_thread: {
    enabled: true,
    auto_archive_duration_minutes: 1440,
    no_thread_channel_ids: [],
  },
  advanced: {
    dedupe_ttl_ms: 300000,
    message_context_ttl_ms: 2592000000,
    card_action_dedupe_ttl_ms: 900000,
    inline_media_max_bytes: 524288,
    stream_update_interval_ms: 100,
    thread_ownership_cache_ttl_ms: 86400000,
    stream_chunk_soft_limit: 1850,
    application_commands_sync_policy: "safe",
    commands_sync_policy: "replace",
    poll_timeout_s: 30,
    poll_limit: 100,
    poll_retry_max: 10,
    flood_wait_max_ms: 5000,
  },
  transport: {
    mode: "polling",
    set_webhook: true,
    secret_token: "",
  },
  secret_status: {
    app_secret: "missing",
    bot_token: "missing",
    client_secret: "missing",
    "transport.secret_token": "missing",
  },
}

interface SetupAppProps {
  app_name: string
  adapter_catalog?: AdapterCatalogEntry[]
  adapters?: AdapterEntry[]
  check_path: string
  generated_secret_path?: string
  save_path: string
  back_path: string
  web_login_callback_origin?: string
}

export default function SetupApp({
  app_name,
  adapter_catalog = [],
  adapters = [],
  check_path,
  generated_secret_path = "",
  save_path,
  back_path,
  web_login_callback_origin = "",
}: SetupAppProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const [entries, setEntries] = React.useState<AdapterEntry[]>(() => normalizeEntries(adapters))
  const [checks, setChecks] = React.useState<ChecksMap>({})
  const [serverErrors, setServerErrors] = React.useState<AdapterError[]>([])
  const [checkingId, setCheckingId] = React.useState<string | null>(null)
  const [saving, setSaving] = React.useState(false)
  const [sheetOpen, setSheetOpen] = React.useState(false)
  const [editingIndex, setEditingIndex] = React.useState<number | null>(null)
  const [draft, setDraft] = React.useState<AdapterEntry>(() => newEntry(adapter_catalog))
  const [draftErrors, setDraftErrors] = React.useState<AdapterError[]>([])

  const listErrors = React.useMemo(() => validateEntries(entries, translate), [entries, translate])
  const enabledEntries = entries.filter(entry => entry.enabled !== false)
  const allEnabledChecked = enabledEntries.every(entry => checks[entry.id]?.status === "success")
  const canSave = enabledEntries.length > 0 && listErrors.length === 0 && allEnabledChecked && !saving

  const clearChecks = React.useCallback((ids: string | Array<string | null | undefined>) => {
    const idList = Array.isArray(ids) ? ids : [ids]

    setChecks(current => {
      const next = { ...current }
      for (const id of idList) {
        if (id) delete next[id]
      }
      return next
    })
  }, [])

  const openNewSheet = () => {
    setEditingIndex(null)
    setDraft(newEntry(adapter_catalog))
    setDraftErrors([])
    setSheetOpen(true)
  }

  const openEditSheet = (index: number) => {
    setEditingIndex(index)
    setDraft(clone(entries[index]))
    setDraftErrors([])
    setSheetOpen(true)
  }

  const applyDraft = () => {
    const prepared = prepareEntryForSave(draft)
    const errors = validateDraft(prepared, entries, editingIndex, translate)

    if (errors.length > 0) {
      setDraftErrors(errors)
      return
    }

    const previousId = editingIndex === null ? null : (entries[editingIndex]?.id ?? null)

    setEntries(current => {
      if (editingIndex === null) return [...current, prepared]

      return current.map((entry, index) => (index === editingIndex ? prepared : entry))
    })

    clearChecks([previousId, prepared.id].filter((value): value is string => Boolean(value)))
    setServerErrors([])
    setSheetOpen(false)
  }

  const removeEntry = (index: number) => {
    const entry = entries[index]

    setEntries(current => current.filter((_item, itemIndex) => itemIndex !== index))
    clearChecks(entry.id)
    setServerErrors([])
  }

  const runCheck = async (entry: AdapterEntry) => {
    const prepared = prepareEntryForSave(entry)
    const errors = validateEntry(prepared, translate)

    if (errors.length > 0) {
      setServerErrors(errors)
      return
    }

    setCheckingId(prepared.id)
    setServerErrors([])

    const response = await postJson(check_path, { adapter: prepared })

    setCheckingId(null)

    if (response.redirect_to) {
      window.location.assign(response.redirect_to)
      return
    }

    if (!response.ok) {
      setChecks(current => ({
        ...current,
        [prepared.id]: { status: "error", errors: response.errors || [] },
      }))
      setServerErrors(response.errors || [])
      return
    }

    setChecks(current => ({
      ...current,
      [prepared.id]: {
        status: "success",
        token: response.connectivity_token,
        result: response.result,
      },
    }))

    if (response.adapter) {
      setEntries(current =>
        current.map(entry => (entry.id === prepared.id ? mergeGeneratedSecrets(entry, response.adapter!) : entry)),
      )
    }
  }

  const saveAdapters = async () => {
    if (!canSave) return

    setSaving(true)
    setServerErrors([])

    const preparedEntries = entries.map(prepareEntryForSave)
    const response = await postJson(save_path, {
      adapters: preparedEntries,
      connectivity_tokens: Object.fromEntries(
        preparedEntries
          .map(entry => [entry.id, checks[entry.id]] as const)
          .filter((pair): pair is readonly [string, CheckSuccess] => pair[1]?.status === "success")
          .map(([id, check]) => [id, check.token]),
      ),
    })

    setSaving(false)

    if (response.redirect_to) {
      window.location.assign(response.redirect_to)
      return
    }

    if (!response.ok) {
      setServerErrors(response.errors || [])
    }
  }

  return (
    <SetupLayout title={translate("web.setup.title")} appName={app_name}>
      <section className="grid flex-1 place-items-center py-8 sm:py-10">
        <Card size="sm" className="w-full max-w-4xl gap-0 bg-card py-0">
          <CardHeader className="border-b border-border px-5 py-4 sm:px-6">
            <div className="min-w-0">
              <p className="text-xs font-medium text-primary">{translate("web.setup.gateway.step")}</p>
              <CardTitle className="mt-1 text-xl font-semibold">{translate("web.setup.gateway.heading")}</CardTitle>
            </div>
          </CardHeader>

          <CardContent className="px-5 py-5 sm:px-6">
            <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0">
                <p className="mt-1 text-sm text-muted-foreground">{translate("web.setup.gateway.description")}</p>
              </div>
              {entries.length > 0 ? (
                <Button type="button" onClick={openNewSheet}>
                  <RiAddLine data-icon="inline-start" />
                  <span>{translate("web.setup.gateway.add_adapter")}</span>
                </Button>
              ) : null}
            </div>

            <ErrorList errors={[...listErrors, ...serverErrors]} />

            {entries.length === 0 ? (
              <EmptyState onAdd={openNewSheet} />
            ) : (
              <div className="grid gap-3">
                {entries.map((entry, index) => (
                  <AdapterRow
                    key={entry.id}
                    entry={entry}
                    catalog={adapter_catalog}
                    check={checks[entry.id]}
                    checking={checkingId === entry.id}
                    onCheck={() => runCheck(entry)}
                    onEdit={() => openEditSheet(index)}
                    onRemove={() => removeEntry(index)}
                  />
                ))}
              </div>
            )}
          </CardContent>

          <CardFooter className="flex-col items-stretch justify-between gap-3 border-t border-border px-5 py-4 sm:flex-row sm:items-center sm:px-6">
            <Button type="button" variant="ghost" onClick={() => window.location.assign(back_path)}>
              <RiArrowLeftLine data-icon="inline-start" />
              <span>{translate("web.setup.gateway.actions.back_to_llm")}</span>
            </Button>
            <Button type="button" onClick={saveAdapters} disabled={!canSave}>
              <RiSaveLine data-icon="inline-start" />
              <span>{saving ? translate("web.setup.gateway.saving") : translate("web.setup.gateway.save")}</span>
            </Button>
          </CardFooter>
        </Card>
      </section>

      <AdapterSheet
        open={sheetOpen}
        onOpenChange={setSheetOpen}
        draft={draft}
        setDraft={next => {
          setDraft(next)
          setDraftErrors([])
        }}
        errors={draftErrors}
        catalog={adapter_catalog}
        entries={entries}
        editing={editingIndex !== null}
        webLoginCallbackOrigin={web_login_callback_origin}
        generatedSecretPath={generated_secret_path}
        onApply={applyDraft}
      />
    </SetupLayout>
  )
}

interface AdapterRowProps {
  entry: AdapterEntry
  catalog: AdapterCatalogEntry[]
  check: CheckResult | undefined
  checking: boolean
  onCheck: () => void
  onEdit: () => void
  onRemove: () => void
}

function AdapterRow({ entry, catalog, check, checking, onCheck, onEdit, onRemove }: AdapterRowProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const prepared = prepareEntryForSave(entry)
  const invalid = prepared.enabled && validateEntry(prepared, translate).length > 0
  const connected = check?.status === "success"
  const tenantPolicy = prepared.authn.external_org_members
  const metadata = [
    prepared.channel_id || translate("web.setup.gateway.fields.channel_id"),
    prepared.adapter === "feishu" ? domainLabel(prepared.domain) : adapterLabel(prepared.adapter, catalog),
    prepared.web_login_disabled ? translate("web.setup.gateway.web_login.disabled_summary") : null,
    tenantPolicy.enabled && tenantPolicy.tenant_key
      ? translate("web.setup.gateway.authorization.tenant_key_summary", {
          values: { tenant_key: tenantPolicy.tenant_key },
        })
      : null,
  ].filter(Boolean)

  return (
    <div className="grid gap-4 border border-border bg-background-secondary p-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
      <div className="min-w-0">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <p className="min-w-0 truncate text-sm font-medium">{adapterLabel(prepared.adapter, catalog)}</p>
          <Badge variant="outline">{transportLabel(prepared.adapter)}</Badge>
        </div>
        <p className="mt-2 truncate text-xs leading-5 text-muted-foreground">{metadata.join(" · ")}</p>
      </div>

      <div className="flex flex-wrap items-center justify-start gap-2 sm:justify-end">
        <ConnectionBadge
          disabled={!prepared.enabled}
          invalid={invalid}
          checking={checking}
          connected={connected}
          error={check?.status === "error"}
        />
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={!prepared.enabled || invalid || checking}
          onClick={onCheck}>
          <RiPlugLine data-icon="inline-start" />
          <span>{translate("web.setup.gateway.actions.check")}</span>
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={translate("web.setup.gateway.actions.edit")}
          onClick={onEdit}>
          <RiEditLine />
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={translate("web.setup.gateway.actions.remove")}
          onClick={onRemove}>
          <RiDeleteBinLine />
        </Button>
      </div>
    </div>
  )
}

function EmptyState({ onAdd }: { onAdd: () => void }) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <div className="grid min-h-48 place-items-center border border-border bg-background-secondary px-4 py-10 text-center">
      <div className="grid justify-items-center gap-4">
        <div>
          <p className="text-base font-medium">{translate("web.setup.gateway.empty_title")}</p>
          <p className="mt-2 text-sm text-muted-foreground">{translate("web.setup.gateway.empty_description")}</p>
        </div>
        <Button type="button" onClick={onAdd}>
          <RiAddLine data-icon="inline-start" />
          <span>{translate("web.setup.gateway.add_adapter")}</span>
        </Button>
      </div>
    </div>
  )
}

interface AdapterSheetProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  draft: AdapterEntry
  setDraft: (entry: AdapterEntry) => void
  errors: AdapterError[]
  catalog: AdapterCatalogEntry[]
  entries: AdapterEntry[]
  editing: boolean
  webLoginCallbackOrigin: string
  generatedSecretPath: string
  onApply: () => void
}

function AdapterSheet({
  open,
  onOpenChange,
  draft,
  setDraft,
  errors,
  catalog,
  entries,
  editing,
  webLoginCallbackOrigin,
  generatedSecretPath,
  onApply,
}: AdapterSheetProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const [mode, setMode] = React.useState<"select" | "configure">(editing ? "configure" : "select")
  const [advancedOpen, setAdvancedOpen] = React.useState(false)
  const advancedContentRef = React.useRef<HTMLDivElement | null>(null)
  const catalogOptions: AdapterCatalogEntry[] = catalog.length
    ? catalog
    : [
        {
          adapter: "feishu",
          label: "Feishu / Lark",
          default_entry: FALLBACK_ENTRY,
          authn_policies: [{ type: "external_org_members" }],
        },
      ]
  const docUrl = configDocUrl(draft, catalogOptions)
  const supportsExternalOrgMembers = connectorSupportsAuthnPolicy(draft.adapter, catalogOptions, "external_org_members")
  const callbackUrl = callbackUrlFor(webLoginCallbackOrigin, draft.adapter, draft.channel_id)
  const telegramWebhookUrl = telegramWebhookUrlFor(
    webLoginCallbackOrigin,
    draft.adapter,
    draft.channel_id,
    draft.transport.mode,
  )
  const fieldErrors = React.useMemo(() => errorsByField(errors), [errors])
  const formErrors = React.useMemo(() => errorsWithoutFields(errors), [errors])

  React.useEffect(() => {
    if (!open) return

    setAdvancedOpen(false)
    setMode(editing ? "configure" : "select")
  }, [editing, open])

  React.useEffect(() => {
    if (!advancedOpen) return

    requestAnimationFrame(() => {
      advancedContentRef.current?.scrollIntoView({ block: "nearest" })
    })
  }, [advancedOpen])

  const update = (path: string[], value: unknown) => {
    setDraft(setPath(draft, path, value))
  }

  const chooseAdapter = (catalogEntry: AdapterCatalogEntry) => {
    const adapter = catalogEntry.adapter
    const next = mergeEntry({
      ...(catalogEntry?.default_entry || {}),
      adapter,
      id: nextEntryId(adapter),
      channel_id: nextDefaultChannelId(adapter, entries),
    })

    setDraft(next)
    setMode("configure")
  }

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        className={[
          "top-1/2! right-1/2! bottom-auto! left-auto! max-w-none! translate-x-1/2! -translate-y-1/2! overflow-hidden border border-border",
          mode === "select"
            ? "h-auto! max-h-[min(42rem,calc(100vh-2rem))]! w-[min(48rem,calc(100vw-2rem))]!"
            : "h-[min(42rem,calc(100vh-2rem))]! w-[min(56rem,calc(100vw-2rem))]!",
        ].join(" ")}
        showCloseButton={false}>
        <SheetHeader className="shrink-0 border-b border-border px-5 py-5 sm:px-6">
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <SheetTitle>
                {mode === "select"
                  ? translate("web.setup.gateway.sheet.select_title")
                  : editing
                    ? translate("web.setup.gateway.sheet.edit_title")
                    : translate("web.setup.gateway.sheet.add_title")}
              </SheetTitle>
              <SheetDescription>
                {mode === "select" ? (
                  ""
                ) : (
                  <>
                    {adapterLabel(draft.adapter, catalogOptions)}
                    {" · "}
                    {transportLabel(draft.adapter)}
                  </>
                )}
              </SheetDescription>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              {mode === "configure" && docUrl ? (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => window.open(docUrl, "_blank", "noopener,noreferrer")}>
                  <RiExternalLinkLine data-icon="inline-start" />
                  <span>{translate("web.setup.gateway.docs")}</span>
                </Button>
              ) : null}
              <Button
                type="button"
                size="icon-sm"
                variant="ghost"
                aria-label={translate("app.close")}
                onClick={() => onOpenChange(false)}>
                <RiCloseLine />
              </Button>
            </div>
          </div>
        </SheetHeader>

        <div className="grid min-h-0 flex-1 gap-5 overflow-y-auto px-5 py-5 sm:px-6">
          {mode === "select" ? (
            <AdapterTypeChooser catalog={catalogOptions} onChoose={chooseAdapter} />
          ) : (
            <>
              <ErrorList errors={formErrors} />

              <FormSection title={translate("web.setup.gateway.sections.channel")}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field
                    label={translate("web.setup.gateway.fields.channel_id")}
                    required
                    error={fieldErrors.channel_id}>
                    <Input
                      value={draft.channel_id}
                      onChange={event => update(["channel_id"], event.target.value)}
                      autoComplete="off"
                      aria-invalid={Boolean(fieldErrors.channel_id) || undefined}
                      autoFocus
                      required
                    />
                  </Field>

                  {draft.adapter === "feishu" ? (
                    <Field label={translate("web.setup.gateway.fields.domain")}>
                      <Select
                        value={draft.domain}
                        onValueChange={(value: string | null) => update(["domain"], value ?? "")}>
                        <SelectTrigger className="w-full">
                          <span data-slot="select-value">{domainLabel(draft.domain)}</span>
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem value="feishu">Feishu</SelectItem>
                          <SelectItem value="lark">Lark</SelectItem>
                        </SelectContent>
                      </Select>
                    </Field>
                  ) : null}
                </div>

                <div className="grid gap-4 border border-border bg-background-secondary p-4">
                  <div className="flex items-start justify-between gap-4">
                    <div className="min-w-0">
                      <p className="text-sm font-medium">{translate("web.setup.gateway.web_login.disabled")}</p>
                      <p className="mt-1 text-sm leading-5 text-muted-foreground">
                        {translate("web.setup.gateway.web_login.disabled_description")}
                      </p>
                    </div>
                    <Switch
                      checked={draft.web_login_disabled}
                      onCheckedChange={(checked: boolean) => update(["web_login_disabled"], checked)}
                      aria-label={translate("web.setup.gateway.web_login.disabled")}
                    />
                  </div>

                  {callbackUrl ? (
                    <div className="grid gap-2 border-t border-border pt-4">
                      <p className="text-xs text-muted-foreground">
                        {translate("web.setup.gateway.web_login.callback_url")}
                      </p>
                      <code className="block break-all bg-background px-3 py-2 text-xs">{callbackUrl}</code>
                    </div>
                  ) : null}
                  {telegramWebhookUrl ? (
                    <div className="grid gap-2 border-t border-border pt-4">
                      <p className="text-xs text-muted-foreground">
                        {translate("web.setup.gateway.telegram.webhook_url")}
                      </p>
                      <code className="block break-all bg-background px-3 py-2 text-xs">{telegramWebhookUrl}</code>
                    </div>
                  ) : null}
                </div>
              </FormSection>

              {supportsExternalOrgMembers ? (
                <FormSection title={translate("web.setup.gateway.sections.authorization")}>
                  <div className="grid gap-4">
                    <div className="flex items-start justify-between gap-4 border border-border bg-background-secondary p-4">
                      <div className="min-w-0">
                        <p className="text-sm font-medium">
                          {translate("web.setup.gateway.authorization.external_org_members")}
                        </p>
                        <p className="mt-1 text-sm leading-5 text-muted-foreground">
                          {translate("web.setup.gateway.authorization.external_org_members_description")}
                        </p>
                      </div>
                      <Switch
                        checked={Boolean(draft.authn.external_org_members.enabled)}
                        onCheckedChange={(checked: boolean) =>
                          update(["authn", "external_org_members", "enabled"], checked)
                        }
                        aria-label={translate("web.setup.gateway.authorization.external_org_members")}
                      />
                    </div>

                    {draft.authn.external_org_members.enabled ? (
                      <Field
                        label={translate("web.setup.gateway.fields.tenant_key")}
                        required
                        error={fieldErrors["authn.external_org_members.tenant_key"]}>
                        <Input
                          value={draft.authn.external_org_members.tenant_key}
                          onChange={event =>
                            update(["authn", "external_org_members", "tenant_key"], event.target.value)
                          }
                          autoComplete="off"
                          aria-invalid={Boolean(fieldErrors["authn.external_org_members.tenant_key"]) || undefined}
                          required
                        />
                      </Field>
                    ) : null}
                  </div>
                </FormSection>
              ) : null}

              <FormSection title={translate("web.setup.gateway.sections.credentials")}>
                <CredentialFields draft={draft} update={update} fieldErrors={fieldErrors} />
              </FormSection>

              {draft.adapter === "discord" ? (
                <FormSection title={translate("web.setup.gateway.sections.behavior")}>
                  <DiscordBehaviorFields draft={draft} update={update} />
                </FormSection>
              ) : null}

              {draft.adapter === "telegram" ? (
                <FormSection title={translate("web.setup.gateway.sections.behavior")}>
                  <TelegramBehaviorFields
                    draft={draft}
                    update={update}
                    catalog={catalogOptions}
                    generatedSecretPath={generatedSecretPath}
                  />
                </FormSection>
              ) : null}

              <Collapsible open={advancedOpen} onOpenChange={setAdvancedOpen}>
                <FormSection
                  title={
                    <CollapsibleTrigger className="flex w-full cursor-pointer items-center justify-between gap-3 text-left">
                      <span>{translate("web.setup.gateway.sections.advanced")}</span>
                      <RiArrowDownSLine
                        className={[
                          "size-4 shrink-0 text-muted-foreground transition-transform",
                          advancedOpen ? "rotate-180" : "",
                        ].join(" ")}
                      />
                    </CollapsibleTrigger>
                  }>
                  <CollapsibleContent>
                    <div ref={advancedContentRef} className="grid gap-4 pt-1 md:grid-cols-3">
                      {advancedFieldsFor(draft.adapter).map(field => (
                        <Field key={field} label={translate(`web.setup.gateway.fields.${field}`)}>
                          <Input
                            type="number"
                            min="0"
                            value={numberValue(draft.advanced[field] ?? FALLBACK_ENTRY.advanced[field])}
                            onChange={event => update(["advanced", field], numberValue(event.target.value))}
                          />
                        </Field>
                      ))}

                      {draft.adapter === "discord" ? (
                        <Field label={translate("web.setup.gateway.fields.application_commands_sync_policy")}>
                          <Select
                            value={syncPolicyValue(draft.advanced.application_commands_sync_policy)}
                            onValueChange={(value: string | null) =>
                              update(["advanced", "application_commands_sync_policy"], syncPolicyValue(value))
                            }>
                            <SelectTrigger className="w-full">
                              <span data-slot="select-value">
                                {syncPolicyValue(draft.advanced.application_commands_sync_policy)}
                              </span>
                            </SelectTrigger>
                            <SelectContent>
                              {DISCORD_SYNC_POLICIES.map(policy => (
                                <SelectItem key={policy} value={policy}>
                                  {policy}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </Field>
                      ) : null}

                      {draft.adapter === "telegram" ? (
                        <Field label={translate("web.setup.gateway.fields.commands_sync_policy")}>
                          <Select
                            value={telegramSyncPolicyValue(draft.advanced.commands_sync_policy)}
                            onValueChange={(value: string | null) =>
                              update(["advanced", "commands_sync_policy"], telegramSyncPolicyValue(value))
                            }>
                            <SelectTrigger className="w-full">
                              <span data-slot="select-value">
                                {telegramSyncPolicyValue(draft.advanced.commands_sync_policy)}
                              </span>
                            </SelectTrigger>
                            <SelectContent>
                              {TELEGRAM_SYNC_POLICIES.map(policy => (
                                <SelectItem key={policy} value={policy}>
                                  {policy}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </Field>
                      ) : null}
                    </div>
                  </CollapsibleContent>
                </FormSection>
              </Collapsible>
            </>
          )}
        </div>

        {mode === "configure" ? (
          <SheetFooter className="shrink-0">
            <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
              {translate("web.setup.gateway.sheet.cancel")}
            </Button>
            <Button type="button" onClick={onApply}>
              {editing ? <RiSaveLine data-icon="inline-start" /> : <RiAddLine data-icon="inline-start" />}
              <span>
                {editing
                  ? translate("web.setup.gateway.sheet.save_changes")
                  : translate("web.setup.gateway.add_adapter")}
              </span>
            </Button>
          </SheetFooter>
        ) : null}
      </SheetContent>
    </Sheet>
  )
}

interface AdapterTypeChooserProps {
  catalog: AdapterCatalogEntry[]
  onChoose: (catalogEntry: AdapterCatalogEntry) => void
}

function AdapterTypeChooser({ catalog, onChoose }: AdapterTypeChooserProps) {
  return (
    <div
      className={[
        "grid self-start gap-3",
        catalog.length > 1 ? "sm:grid-cols-2" : "sm:grid-cols-[minmax(0,24rem)]",
      ].join(" ")}>
      {catalog.map(item => (
        <button
          key={item.adapter}
          type="button"
          className="group grid min-h-28 gap-4 border border-border bg-background-secondary p-4 text-left transition-colors hover:border-primary hover:bg-muted focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 focus-visible:outline-none"
          onClick={() => onChoose(item)}>
          <span className="flex items-center justify-between gap-4">
            <span className="min-w-0 truncate text-base font-semibold">
              {item.label || adapterLabel(item.adapter, catalog)}
            </span>
            <RiArrowRightSLine className="size-5 shrink-0 text-muted-foreground group-hover:text-primary" />
          </span>
          <span className="flex flex-wrap gap-2">
            <Badge variant="outline">{transportLabel(item.adapter)}</Badge>
          </span>
        </button>
      ))}
    </div>
  )
}

function FormSection({ title, children }: { title: React.ReactNode; children: React.ReactNode }) {
  return (
    <section className="grid gap-3">
      <h3 className="border-b border-border pb-2 text-sm font-semibold">{title}</h3>
      {children}
    </section>
  )
}

interface FieldProps {
  label: React.ReactNode
  children: React.ReactNode
  required?: boolean
  error?: string
}

function Field({ label, children, required = false, error }: FieldProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <div className="grid gap-1.5">
      <Label className="items-baseline">
        <span>{label}</span>
        {required ? <span className="text-muted-foreground">{translate("web.setup.gateway.required")}</span> : null}
      </Label>
      {children}
      {error ? <p className="text-xs leading-4 text-destructive">{error}</p> : null}
    </div>
  )
}

interface CredentialFieldsProps {
  draft: AdapterEntry
  update: (path: string[], value: unknown) => void
  fieldErrors: Record<string, string>
}

function CredentialFields({ draft, update, fieldErrors }: CredentialFieldsProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  if (draft.adapter === "telegram") {
    return (
      <div className="grid gap-4 sm:grid-cols-2">
        <SecretFieldInput
          label={translate("web.setup.gateway.fields.bot_token")}
          value={draft.credentials.bot_token || ""}
          status={draft.secret_status?.bot_token}
          onChange={value => update(["credentials", "bot_token"], value)}
          required
          error={fieldErrors["credentials.bot_token"]}
        />
        <Field label={translate("web.setup.gateway.fields.bot_username")}>
          <Input
            value={draft.credentials.bot_username || ""}
            onChange={event => update(["credentials", "bot_username"], event.target.value)}
            autoComplete="off"
          />
        </Field>
      </div>
    )
  }

  if (draft.adapter === "discord") {
    return (
      <div className="grid gap-4 sm:grid-cols-2">
        <Field
          label={translate("web.setup.gateway.fields.application_id")}
          required
          error={fieldErrors["credentials.application_id"]}>
          <Input
            value={draft.credentials.application_id || ""}
            onChange={event => update(["credentials", "application_id"], event.target.value)}
            autoComplete="off"
            aria-invalid={Boolean(fieldErrors["credentials.application_id"]) || undefined}
            required
          />
        </Field>
        <SecretFieldInput
          label={translate("web.setup.gateway.fields.bot_token")}
          value={draft.credentials.bot_token || ""}
          status={draft.secret_status?.bot_token}
          onChange={value => update(["credentials", "bot_token"], value)}
          required
          error={fieldErrors["credentials.bot_token"]}
        />
        <SecretFieldInput
          label={translate("web.setup.gateway.fields.client_secret")}
          value={draft.credentials.client_secret || ""}
          status={draft.secret_status?.client_secret}
          onChange={value => update(["credentials", "client_secret"], value)}
          required={!draft.web_login_disabled}
          error={fieldErrors["credentials.client_secret"]}
        />
      </div>
    )
  }

  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Field label={translate("web.setup.gateway.fields.app_id")} required error={fieldErrors["credentials.app_id"]}>
        <Input
          value={draft.credentials.app_id || ""}
          onChange={event => update(["credentials", "app_id"], event.target.value)}
          autoComplete="off"
          aria-invalid={Boolean(fieldErrors["credentials.app_id"]) || undefined}
          required
        />
      </Field>
      <SecretFieldInput
        label={translate("web.setup.gateway.fields.app_secret")}
        value={draft.credentials.app_secret || ""}
        status={draft.secret_status?.app_secret}
        onChange={value => update(["credentials", "app_secret"], value)}
        required
        error={fieldErrors["credentials.app_secret"]}
      />
    </div>
  )
}

interface TelegramBehaviorFieldsProps {
  draft: AdapterEntry
  update: (path: string[], value: unknown) => void
  catalog: AdapterCatalogEntry[]
  generatedSecretPath: string
}

function TelegramBehaviorFields({ draft, update, catalog, generatedSecretPath }: TelegramBehaviorFieldsProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const attention = draft.attention || FALLBACK_ENTRY.attention!
  const transport = draft.transport || FALLBACK_ENTRY.transport!
  const webhookSecretField = generatedSecretField(catalog, draft.adapter, ["transport", "secret_token"])

  return (
    <div className="grid gap-4">
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label={translate("web.setup.gateway.fields.transport_mode")}>
          <Select
            value={transport.mode === "webhook" ? "webhook" : "polling"}
            onValueChange={(value: string | null) =>
              update(["transport", "mode"], value === "webhook" ? "webhook" : "polling")
            }>
            <SelectTrigger className="w-full">
              <span data-slot="select-value">{transport.mode === "webhook" ? "webhook" : "polling"}</span>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="polling">polling</SelectItem>
              <SelectItem value="webhook">webhook</SelectItem>
            </SelectContent>
          </Select>
        </Field>

        <div className="flex items-start justify-between gap-4 border border-border bg-background-secondary p-4">
          <div className="min-w-0">
            <p className="text-sm font-medium">{translate("web.setup.gateway.telegram.set_webhook")}</p>
            <p className="mt-1 text-sm leading-5 text-muted-foreground">
              {translate("web.setup.gateway.telegram.set_webhook_description")}
            </p>
          </div>
          <Switch
            checked={transport.set_webhook !== false}
            onCheckedChange={(checked: boolean) => update(["transport", "set_webhook"], checked)}
            aria-label={translate("web.setup.gateway.telegram.set_webhook")}
          />
        </div>
      </div>

      {transport.mode === "webhook" && webhookSecretField ? (
        <GeneratedSecretField
          entry={draft}
          field={webhookSecretField}
          generatedSecretPath={generatedSecretPath}
          update={update}
        />
      ) : null}

      <div className="grid gap-4 sm:grid-cols-2">
        <Field label={translate("web.setup.gateway.fields.allowed_chat_ids")}>
          <Input
            value={stringListValue(attention.allowed_chat_ids)}
            onChange={event => update(["attention", "allowed_chat_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>
        <Field label={translate("web.setup.gateway.fields.ignored_chat_ids")}>
          <Input
            value={stringListValue(attention.ignored_chat_ids)}
            onChange={event => update(["attention", "ignored_chat_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>
        <Field label={translate("web.setup.gateway.fields.ignored_thread_ids")}>
          <Input
            value={stringListValue(attention.ignored_thread_ids)}
            onChange={event => update(["attention", "ignored_thread_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>
        <Field label={translate("web.setup.gateway.fields.free_response_chat_ids")}>
          <Input
            value={stringListValue(attention.free_response_chat_ids)}
            onChange={event => update(["attention", "free_response_chat_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>
      </div>
    </div>
  )
}

interface GeneratedSecretFieldProps {
  entry: AdapterEntry
  field: AdapterFieldDescriptor
  generatedSecretPath: string
  update: (path: string[], value: unknown) => void
}

function GeneratedSecretField({ entry, field, generatedSecretPath, update }: GeneratedSecretFieldProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const [busy, setBusy] = React.useState(false)
  const [error, setError] = React.useState("")
  const value = stringAtPath(entry, field.path)
  const status = entry.secret_status?.[field.path.join(".") as SecretField]
  const canCopy = Boolean(value)

  const generate = async () => {
    if (!generatedSecretPath) {
      setError(translate("web.setup.gateway.generated_secret.unavailable"))
      return
    }

    setBusy(true)
    setError("")

    const response = await postJson(generatedSecretPath, {
      adapter: entry.adapter,
      path: field.path,
    })

    setBusy(false)

    if (response.redirect_to) {
      window.location.assign(response.redirect_to)
      return
    }

    if (response.ok && response.value) {
      update(field.path, response.value)
      return
    }

    setError(response.errors?.[0]?.message || translate("web.setup.gateway.generated_secret.failed"))
  }

  const copy = async () => {
    if (!value) return
    await navigator.clipboard?.writeText(value)
  }

  return (
    <div className="grid gap-3 border border-border bg-background-secondary p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <p className="text-sm font-medium">{translate("web.setup.gateway.generated_secret.telegram_title")}</p>
          <p className="mt-1 text-sm leading-5 text-muted-foreground">
            {translate("web.setup.gateway.generated_secret.telegram_description")}
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          {canCopy ? (
            <Button type="button" size="sm" variant="outline" onClick={copy}>
              <RiFileCopyLine data-icon="inline-start" />
              <span>{translate("web.setup.gateway.generated_secret.copy")}</span>
            </Button>
          ) : null}
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={generate}>
            {canCopy ? <RiRefreshLine data-icon="inline-start" /> : <RiKeyLine data-icon="inline-start" />}
            <span>
              {canCopy
                ? translate("web.setup.gateway.generated_secret.rotate")
                : translate("web.setup.gateway.generated_secret.generate")}
            </span>
          </Button>
        </div>
      </div>

      {value ? (
        <Input value={value} readOnly autoComplete="off" />
      ) : status === "stored" ? (
        <Badge variant="secondary" className="w-fit">
          {translate("web.setup.gateway.secret_stored_badge")}
        </Badge>
      ) : null}

      {error ? <p className="text-xs leading-4 text-destructive">{error}</p> : null}
    </div>
  )
}

interface DiscordBehaviorFieldsProps {
  draft: AdapterEntry
  update: (path: string[], value: unknown) => void
}

function DiscordBehaviorFields({ draft, update }: DiscordBehaviorFieldsProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const attention = draft.attention || FALLBACK_ENTRY.attention!
  const autoThread = draft.auto_thread || FALLBACK_ENTRY.auto_thread!

  return (
    <div className="grid gap-4">
      <div className="flex items-start justify-between gap-4 border border-border bg-background-secondary p-4">
        <div className="min-w-0">
          <p className="text-sm font-medium">{translate("web.setup.gateway.discord.auto_thread_enabled")}</p>
          <p className="mt-1 text-sm leading-5 text-muted-foreground">
            {translate("web.setup.gateway.discord.auto_thread_enabled_description")}
          </p>
        </div>
        <Switch
          checked={autoThread.enabled !== false}
          onCheckedChange={(checked: boolean) => update(["auto_thread", "enabled"], checked)}
          aria-label={translate("web.setup.gateway.discord.auto_thread_enabled")}
        />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Field label={translate("web.setup.gateway.fields.auto_archive_duration_minutes")}>
          <Input
            type="number"
            min="1"
            value={numberValue(autoThread.auto_archive_duration_minutes)}
            onChange={event =>
              update(["auto_thread", "auto_archive_duration_minutes"], numberValue(event.target.value))
            }
          />
        </Field>

        <Field label={translate("web.setup.gateway.fields.no_thread_channel_ids")}>
          <Input
            value={stringListValue(autoThread.no_thread_channel_ids)}
            onChange={event => update(["auto_thread", "no_thread_channel_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>

        <Field label={translate("web.setup.gateway.fields.allowed_channel_ids")}>
          <Input
            value={stringListValue(attention.allowed_channel_ids)}
            onChange={event => update(["attention", "allowed_channel_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>

        <Field label={translate("web.setup.gateway.fields.ignored_channel_ids")}>
          <Input
            value={stringListValue(attention.ignored_channel_ids)}
            onChange={event => update(["attention", "ignored_channel_ids"], parseStringList(event.target.value))}
            autoComplete="off"
          />
        </Field>
      </div>
    </div>
  )
}

interface SecretFieldInputProps {
  label: string
  value: string
  status: SecretStatus | undefined
  onChange: (value: string) => void
  required?: boolean
  error?: string
}

function SecretFieldInput({ label, value, status, onChange, required = false, error }: SecretFieldInputProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <Field label={label} required={required} error={error}>
      <div className="grid gap-2">
        <Input
          type="password"
          value={value}
          placeholder={status === "stored" ? translate("web.setup.gateway.secret_stored") : ""}
          onChange={event => onChange(event.target.value)}
          autoComplete="new-password"
          aria-invalid={Boolean(error) || undefined}
          required={required}
        />
        {status === "stored" ? (
          <Badge variant="secondary" className="w-fit">
            {translate("web.setup.gateway.secret_stored_badge")}
          </Badge>
        ) : null}
      </div>
    </Field>
  )
}

interface ConnectionBadgeProps {
  disabled: boolean
  invalid: boolean
  checking: boolean
  connected: boolean
  error: boolean
}

function ConnectionBadge({ disabled, invalid, checking, connected, error }: ConnectionBadgeProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  if (disabled) {
    return <Badge variant="secondary">{translate("web.setup.gateway.status.disabled")}</Badge>
  }

  if (invalid) {
    return <Badge variant="destructive">{translate("web.setup.gateway.status.invalid")}</Badge>
  }

  if (checking) {
    return <Badge variant="secondary">{translate("web.setup.gateway.status.checking")}</Badge>
  }

  if (connected) {
    return (
      <Badge>
        <RiCheckboxCircleLine />
        <span>{translate("web.setup.gateway.status.connected")}</span>
      </Badge>
    )
  }

  if (error) {
    return <Badge variant="destructive">{translate("web.setup.gateway.status.failed")}</Badge>
  }

  return <Badge variant="outline">{translate("web.setup.gateway.status.unchecked")}</Badge>
}

function ErrorList({ errors }: { errors: AdapterError[] }) {
  if (!errors.length) return null

  return (
    <div className="border-l-4 border-destructive bg-destructive/10 px-4 py-3 text-sm text-destructive">
      {errors.map((error, index) => (
        <p key={`${error.message}-${index}`}>{error.message}</p>
      ))}
    </div>
  )
}

async function postJson(path: string, payload: unknown): Promise<PostJsonResponse> {
  const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content

  try {
    const response = await fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken || "",
      },
      body: JSON.stringify(payload),
    })

    return (await response.json()) as PostJsonResponse
  } catch (error) {
    return {
      ok: false,
      errors: [{ message: error instanceof Error ? error.message : String(error) }],
    }
  }
}

function normalizeEntries(entries: AdapterEntry[]): AdapterEntry[] {
  return entries.map(entry => mergeEntry(entry))
}

function newEntry(catalog: AdapterCatalogEntry[]): AdapterEntry {
  const catalogEntry = catalogEntryFor(catalog, "feishu") || catalog[0]
  const adapter = catalogEntry?.adapter || "feishu"

  return mergeEntry({
    ...(catalogEntry?.default_entry || {}),
    adapter,
    id: nextEntryId(adapter),
    channel_id: "",
  })
}

function nextDefaultChannelId(adapter: string, entries: AdapterEntry[]): string {
  const existingChannelIds = new Set(
    entries
      .map(prepareEntryForSave)
      .filter(entry => entry.adapter === adapter)
      .map(entry => entry.channel_id),
  )

  if (!existingChannelIds.has(adapter)) return adapter

  let suffix = 2
  while (existingChannelIds.has(`${adapter}-${suffix}`)) suffix += 1

  return `${adapter}-${suffix}`
}

function mergeEntry(entry: Partial<AdapterEntry>): AdapterEntry {
  const source = clone(entry || {}) as Partial<AdapterEntry>
  const fallback = clone(FALLBACK_ENTRY)
  const merged: AdapterEntry = {
    ...fallback,
    ...source,
    credentials: {
      ...fallback.credentials,
      ...(source.credentials || {}),
    },
    authn: {
      external_org_members: {
        ...fallback.authn.external_org_members,
        ...(source.authn?.external_org_members || {}),
      },
    },
    attention: {
      ...fallback.attention!,
      ...(source.attention || {}),
    },
    auto_thread: {
      ...fallback.auto_thread!,
      ...(source.auto_thread || {}),
    },
    transport: {
      ...fallback.transport!,
      ...(source.transport || {}),
    },
    advanced: mergeAdvanced(source.advanced),
    secret_status: {
      ...fallback.secret_status,
      ...(source.secret_status || {}),
    },
  }

  for (const field of ["app_secret", "bot_token", "client_secret"] as const) {
    merged.credentials[field] = merged.credentials[field] || ""
  }

  return merged
}

function mergeGeneratedSecrets(entry: AdapterEntry, serverEntry: AdapterEntry): AdapterEntry {
  const merged = mergeEntry(entry)
  const server = mergeEntry(serverEntry)
  const secretToken = server.transport?.secret_token || ""

  if (!secretToken) return merged

  return {
    ...merged,
    transport: {
      ...merged.transport!,
      secret_token: secretToken,
    },
    secret_status: {
      ...merged.secret_status,
      "transport.secret_token":
        server.secret_status?.["transport.secret_token"] || merged.secret_status?.["transport.secret_token"],
    },
  }
}

function prepareEntryForSave(entry: AdapterEntry): AdapterEntry {
  const normalized = mergeEntry(entry)
  const channelId = normalized.channel_id.trim()
  const adapter = normalized.adapter || "feishu"
  const id = channelId ? `${adapter}:${channelId}` : normalized.id

  return {
    id,
    adapter,
    channel_id: channelId,
    enabled: normalized.enabled !== false,
    web_login_disabled: normalized.web_login_disabled === true,
    domain: normalized.domain,
    authn: {
      external_org_members: {
        enabled: Boolean(normalized.authn.external_org_members.enabled),
        tenant_key: normalized.authn.external_org_members.tenant_key.trim(),
      },
    },
    credentials: {
      app_id: (normalized.credentials.app_id || "").trim(),
      app_secret: (normalized.credentials.app_secret || "").trim(),
      application_id: (normalized.credentials.application_id || "").trim(),
      bot_token: (normalized.credentials.bot_token || "").trim(),
      client_secret: (normalized.credentials.client_secret || "").trim(),
      bot_username: (normalized.credentials.bot_username || "").trim(),
    },
    transport: {
      mode: normalized.transport?.mode === "webhook" ? "webhook" : "polling",
      set_webhook: normalized.transport?.set_webhook !== false,
      secret_token: (normalized.transport?.secret_token || "").trim(),
    },
    attention: {
      allowed_channel_ids: normalizeStringList(normalized.attention?.allowed_channel_ids),
      ignored_channel_ids: normalizeStringList(normalized.attention?.ignored_channel_ids),
      allowed_chat_ids: normalizeStringList(normalized.attention?.allowed_chat_ids),
      ignored_chat_ids: normalizeStringList(normalized.attention?.ignored_chat_ids),
      ignored_thread_ids: normalizeStringList(normalized.attention?.ignored_thread_ids),
      require_mention: normalized.attention?.require_mention !== false,
      free_response_chat_ids: normalizeStringList(normalized.attention?.free_response_chat_ids),
    },
    auto_thread: {
      enabled: normalized.auto_thread?.enabled !== false,
      auto_archive_duration_minutes: numberValue(normalized.auto_thread?.auto_archive_duration_minutes || 1440),
      no_thread_channel_ids: normalizeStringList(normalized.auto_thread?.no_thread_channel_ids),
    },
    advanced: mergeAdvanced(normalized.advanced),
    secret_status: normalized.secret_status,
  }
}

function mergeAdvanced(source: Partial<AdapterAdvanced> | undefined): AdapterAdvanced {
  const advanced = Object.fromEntries(
    [...FEISHU_ADVANCED_FIELDS, ...DISCORD_ADVANCED_FIELDS, ...TELEGRAM_ADVANCED_FIELDS].map(field => [
      field,
      numberValue(source?.[field] ?? FALLBACK_ENTRY.advanced[field]),
    ]),
  ) as unknown as AdapterAdvanced

  advanced.application_commands_sync_policy = syncPolicyValue(
    source?.application_commands_sync_policy ?? FALLBACK_ENTRY.advanced.application_commands_sync_policy,
  )
  advanced.commands_sync_policy = telegramSyncPolicyValue(
    source?.commands_sync_policy ?? FALLBACK_ENTRY.advanced.commands_sync_policy,
  )

  return advanced
}

function setPath<T>(object: T, path: string[], value: unknown): T {
  const next = clone(object) as Record<string, unknown>
  let cursor: Record<string, unknown> = next

  for (const key of path.slice(0, -1)) {
    cursor[key] = isPlainObject(cursor[key]) ? { ...(cursor[key] as Record<string, unknown>) } : {}
    cursor = cursor[key] as Record<string, unknown>
  }

  cursor[path[path.length - 1]] = value
  return next as T
}

function validateEntries(entries: AdapterEntry[], t: Translate): AdapterError[] {
  const errors = entries.flatMap(entry => validateEntry(prepareEntryForSave(entry), t))
  const seen = new Set<string>()

  for (const entry of entries.map(prepareEntryForSave).filter(item => item.enabled)) {
    const key = `${entry.adapter}:${entry.channel_id}`
    if (seen.has(key)) {
      errors.push({
        field: "channel_id",
        message: t("web.setup.gateway.errors.duplicate_channel", {
          values: { channel: key },
        }),
      })
    }
    seen.add(key)
  }

  return errors
}

function validateDraft(
  entry: AdapterEntry,
  entries: AdapterEntry[],
  editingIndex: number | null,
  t: Translate,
): AdapterError[] {
  const errors = validateEntry(entry, t)
  const key = `${entry.adapter}:${entry.channel_id}`
  const duplicate = entries
    .map(prepareEntryForSave)
    .some(
      (item, index) =>
        index !== editingIndex &&
        item.enabled &&
        item.adapter === entry.adapter &&
        item.channel_id === entry.channel_id,
    )

  if (duplicate) {
    errors.push({
      field: "channel_id",
      message: t("web.setup.gateway.errors.duplicate_channel", {
        values: { channel: key },
      }),
    })
  }

  return errors
}

function validateEntry(entry: AdapterEntry, t: Translate): AdapterError[] {
  if (!entry.enabled) return []

  const errors: AdapterError[] = []

  if (!entry.channel_id.trim()) {
    errors.push({
      field: "channel_id",
      message: t("web.setup.gateway.errors.channel_id_required"),
    })
  }

  if (entry.adapter === "telegram") {
    if (!hasSecret(entry, "bot_token")) {
      errors.push({
        field: "credentials.bot_token",
        message: t("web.setup.gateway.errors.telegram_bot_token_required"),
      })
    }

    if (entry.transport?.mode === "webhook" && !hasSecret(entry, "transport.secret_token")) {
      errors.push({
        field: "transport.secret_token",
        message: t("web.setup.gateway.errors.telegram_webhook_secret_required"),
      })
    }
  } else if (entry.adapter === "discord") {
    if (!(entry.credentials.application_id || "").trim()) {
      errors.push({
        field: "credentials.application_id",
        message: t("web.setup.gateway.errors.application_id_required"),
      })
    }

    if (!hasSecret(entry, "bot_token")) {
      errors.push({
        field: "credentials.bot_token",
        message: t("web.setup.gateway.errors.bot_token_required"),
      })
    }

    if (!entry.web_login_disabled && !hasSecret(entry, "client_secret")) {
      errors.push({
        field: "credentials.client_secret",
        message: t("web.setup.gateway.errors.client_secret_required"),
      })
    }
  }

  if (entry.adapter === "feishu" && !(entry.credentials.app_id || "").trim()) {
    errors.push({
      field: "credentials.app_id",
      message: t("web.setup.gateway.errors.app_id_required"),
    })
  }

  if (entry.adapter === "feishu" && !hasSecret(entry, "app_secret")) {
    errors.push({
      field: "credentials.app_secret",
      message: t("web.setup.gateway.errors.app_secret_required"),
    })
  }

  if (entry.authn.external_org_members.enabled && !entry.authn.external_org_members.tenant_key.trim()) {
    errors.push({
      field: "authn.external_org_members.tenant_key",
      message: t("web.setup.gateway.errors.tenant_key_required"),
    })
  }

  return errors
}

function errorsByField(errors: AdapterError[]): Record<string, string> {
  return errors.reduce<Record<string, string>>((fields, error) => {
    const field = errorField(error)
    if (field && !fields[field]) fields[field] = error.message
    return fields
  }, {})
}

function errorsWithoutFields(errors: AdapterError[]): AdapterError[] {
  return errors.filter(error => !errorField(error))
}

function errorField(error: AdapterError): string | undefined {
  return error.field || error.details?.field || error.details?.field_path
}

function hasSecret(entry: AdapterEntry, field: SecretField): boolean {
  if (field === "transport.secret_token") {
    return Boolean((entry.transport?.secret_token || "").trim() || entry.secret_status?.[field] === "stored")
  }

  return Boolean((entry.credentials[field] || "").trim() || entry.secret_status?.[field] === "stored")
}

function numberValue(value: unknown): number {
  const parsed = Number.parseInt(String(value), 10)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
}

function syncPolicyValue(value: unknown): string {
  return value === "off" ? "off" : "safe"
}

function telegramSyncPolicyValue(value: unknown): string {
  return value === "off" ? "off" : "replace"
}

function stringListValue(values: string[] | undefined): string {
  return normalizeStringList(values).join(", ")
}

function parseStringList(value: string): string[] {
  return value
    .split(/[,\n]/)
    .map(item => item.trim())
    .filter(Boolean)
}

function normalizeStringList(values: unknown): string[] {
  if (Array.isArray(values)) {
    return values.map(value => String(value).trim()).filter(Boolean)
  }

  if (typeof values === "string") {
    return parseStringList(values)
  }

  return []
}

function nextEntryId(adapter: string): string {
  if (globalThis.crypto?.randomUUID) return `${adapter}:${globalThis.crypto.randomUUID()}`

  return `${adapter}:${Date.now()}:${Math.random().toString(36).slice(2)}`
}

function catalogEntryFor(catalog: AdapterCatalogEntry[], adapter: string): AdapterCatalogEntry | undefined {
  return catalog.find(item => item.adapter === adapter)
}

function configDocUrl(entry: AdapterEntry, catalog: AdapterCatalogEntry[]): string | undefined {
  return catalogEntryFor(catalog, entry.adapter)?.config_doc_url || entry.config_doc_url
}

function connectorSupportsAuthnPolicy(adapter: string, catalog: AdapterCatalogEntry[], policyType: string): boolean {
  const policies = catalogEntryFor(catalog, adapter)?.authn_policies || []

  return policies.some(policy => policy.type === policyType)
}

function generatedSecretField(
  catalog: AdapterCatalogEntry[],
  adapter: string,
  path: string[],
): AdapterFieldDescriptor | undefined {
  return catalogEntryFor(catalog, adapter)?.fields?.find(
    field => isGeneratedSecretType(field.type) && samePath(field.path, path),
  )
}

function isGeneratedSecretType(type: string): boolean {
  return type === "generated_secret" || type === ":generated_secret"
}

function samePath(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((part, index) => part === right[index])
}

function stringAtPath(entry: AdapterEntry, path: string[]): string {
  const value = path.reduce<unknown>((cursor, key) => {
    if (cursor && typeof cursor === "object") return (cursor as Record<string, unknown>)[key]
    return undefined
  }, entry)

  return typeof value === "string" ? value : ""
}

function adapterLabel(adapter: string, catalog: AdapterCatalogEntry[] = []): string {
  return (
    catalogEntryFor(catalog, adapter)?.label || (adapter === "feishu" ? "Feishu / Lark" : adapterLabelFallback(adapter))
  )
}

function adapterLabelFallback(adapter: string): string {
  if (adapter === "telegram") return "Telegram"
  return adapter
}

function transportLabel(adapter: string): string {
  if (adapter === "discord") return "Gateway"
  if (adapter === "telegram") return "Polling/Webhook"
  return "WebSocket"
}

function domainLabel(domain: string): string {
  if (domain === "lark") return "Lark"
  return "Feishu"
}

function callbackUrlFor(origin: string, adapter: string, channelId: string): string {
  const normalized = channelId.trim()
  const normalizedAdapter = adapter.trim() || "feishu"
  const normalizedOrigin = origin.trim().replace(/\/+$/, "")

  if (normalizedAdapter === "telegram") return ""
  if (!normalized || !normalizedOrigin) return ""

  return `${normalizedOrigin}/sessions/${encodeURIComponent(normalizedAdapter)}/${encodeURIComponent(normalized)}/callback`
}

function advancedFieldsFor(adapter: string): Array<keyof AdapterAdvanced> {
  if (adapter === "discord") return DISCORD_ADVANCED_FIELDS
  if (adapter === "telegram") return TELEGRAM_ADVANCED_FIELDS
  return FEISHU_ADVANCED_FIELDS
}

function telegramWebhookUrlFor(origin: string, adapter: string, channelId: string, transportMode: string): string {
  const normalized = channelId.trim()
  const normalizedOrigin = origin.trim().replace(/\/+$/, "")

  if (adapter !== "telegram" || transportMode !== "webhook" || !normalized || !normalizedOrigin) return ""

  return `${normalizedOrigin}/gateway/telegram/${encodeURIComponent(normalized)}/webhook`
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
