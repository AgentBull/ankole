import {
  RiAddLine,
  RiArrowDownSLine,
  RiArrowRightSLine,
  RiCheckboxCircleLine,
  RiCheckLine,
  RiCloseLine,
  RiDeleteBinLine,
  RiEditLine,
  RiFileCopyLine,
  RiPlugLine,
  RiSaveLine,
} from "@remixicon/react"
import { JsonEditor } from "json-edit-react"
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
import SetupLayout from "../Layout"

type Translate = (key: string, options?: { values?: Record<string, unknown>; defaultValue?: string }) => string

type AliasName = "default" | "fast" | "heavy" | "compression"
type SecretStatus = "missing" | "stored"

const ALIASES: AliasName[] = ["default", "fast", "heavy", "compression"]
const DEFAULT_ALIAS_TARGETS: Record<AliasName, AliasName> = {
  default: "default",
  fast: "default",
  heavy: "default",
  compression: "fast",
}

interface ProviderOptionField {
  key: string
  label?: string
  input_type?: "boolean" | "integer" | "float" | "string" | "select" | "json"
  type?: string
  options?: string[]
  required?: boolean
  default?: unknown
  doc?: string
}

interface ProviderCatalogEntryInput {
  id?: string
  provider_id?: string
  label?: string
  default_base_url?: string
  api_key_supported?: boolean
  provider_options?: ProviderOptionField[]
}

interface ProviderCatalogEntry {
  id: string
  label: string
  default_base_url: string
  api_key_supported: boolean
  provider_options: ProviderOptionField[]
}

interface ProviderRow {
  id: string | null
  name: string
  provider_id: string
  model_id: string
  base_url: string
  api_key: string
  api_key_inherits_from: string | null
  provider_options: Record<string, unknown>
  secret_status: { api_key?: SecretStatus }
}

interface ProviderRowInput {
  id?: string | null
  name?: string
  provider_id?: string
  model_id?: string
  base_url?: string
  api_key?: string | null
  api_key_inherits_from?: string | null
  provider_options?: Record<string, unknown>
  secret_status?: { api_key?: SecretStatus }
}

interface PreparedProvider {
  id: string | null
  name: string
  provider_id: string
  model_id: string
  provider_options: Record<string, unknown>
  provider_options_error?: string
  provider_options_field_errors?: Array<{ field: string; error: string }>
  base_url?: string
  api_key?: string | null
  api_key_inherits_from?: string
}

interface InheritSource extends ProviderRow {}

interface AliasBinding {
  kind: "" | "provider" | "alias" | "default" | "default_provider" | "fallback_provider"
  target: string
  source?: string
  alias_name?: string
}

type AliasRows = Record<AliasName, AliasBinding>

interface LLMError {
  field?: string
  message: string
  kind?: string
  details?: { field?: string; field_path?: string }
}

interface CheckSuccess {
  status: "success"
  result?: unknown
}

interface CheckFailure {
  status: "error"
  errors: LLMError[]
}

type CheckResult = CheckSuccess | CheckFailure
type ChecksMap = Record<string, CheckResult | undefined>

interface PostJsonResponse {
  ok?: boolean
  errors?: LLMError[]
  redirect_to?: string
  result?: unknown
}

const JSON_EDITOR_ICON_CLASS =
  "inline-flex size-6 items-center justify-center border border-transparent text-muted-foreground transition-colors hover:bg-muted hover:text-primary"
const JSON_EDITOR_DANGER_ICON_CLASS =
  "inline-flex size-6 items-center justify-center border border-transparent text-muted-foreground transition-colors hover:bg-muted hover:text-destructive"
const JSON_EDITOR_ICONS = {
  add: (
    <span className={JSON_EDITOR_ICON_CLASS}>
      <RiAddLine className="size-4" />
    </span>
  ),
  edit: (
    <span className={JSON_EDITOR_ICON_CLASS}>
      <RiEditLine className="size-4" />
    </span>
  ),
  delete: (
    <span className={JSON_EDITOR_DANGER_ICON_CLASS}>
      <RiDeleteBinLine className="size-4" />
    </span>
  ),
  copy: (
    <span className={JSON_EDITOR_ICON_CLASS}>
      <RiFileCopyLine className="size-4" />
    </span>
  ),
  ok: (
    <span className={JSON_EDITOR_ICON_CLASS}>
      <RiCheckLine className="size-4" />
    </span>
  ),
  cancel: (
    <span className={JSON_EDITOR_DANGER_ICON_CLASS}>
      <RiCloseLine className="size-4" />
    </span>
  ),
  chevron: (
    <span className="inline-flex size-4 items-center justify-center text-muted-foreground">
      <RiArrowRightSLine className="size-4" />
    </span>
  ),
}
const JSON_EDITOR_THEME = {
  displayName: "BullX",
  styles: {
    container: {
      width: "100%",
      backgroundColor: "var(--field)",
      border: "1px solid var(--input)",
      borderRadius: "0",
      color: "var(--foreground)",
      fontFamily: "var(--font-family-mono)",
      fontSize: "0.8125rem",
      lineHeight: "1.25rem",
      padding: "0.75rem 0.75rem 0.75rem 1.5rem",
    },
    collection: { backgroundColor: "transparent" },
    collectionInner: { backgroundColor: "transparent" },
    collectionElement: { backgroundColor: "transparent" },
    dropZone: "var(--border)",
    property: "var(--foreground)",
    bracket: "var(--muted-foreground)",
    itemCount: "var(--muted-foreground)",
    string: "var(--color-cyan-40)",
    number: "var(--color-purple-40)",
    boolean: "var(--color-green-40)",
    null: "var(--color-red-40)",
    input: {
      backgroundColor: "var(--background)",
      border: "1px solid var(--ring)",
      color: "var(--foreground)",
      padding: "0.125rem 0.375rem",
    },
    inputHighlight: "var(--muted)",
    error: "var(--destructive)",
    iconCollection: "var(--muted-foreground)",
    iconEdit: "var(--primary)",
    iconDelete: "var(--destructive)",
    iconAdd: "var(--primary)",
    iconCopy: "var(--muted-foreground)",
    iconOk: "var(--color-green-40)",
    iconCancel: "var(--destructive)",
  },
}

interface SetupLLMAppProps {
  app_name: string
  provider_id_catalog?: Array<string | ProviderCatalogEntryInput>
  providers?: ProviderRowInput[]
  alias_bindings?: AliasBinding[]
  check_path: string
  save_path: string
}

export default function SetupLLMApp({
  app_name,
  provider_id_catalog = [],
  providers = [],
  alias_bindings = [],
  check_path,
  save_path,
}: SetupLLMAppProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const providerCatalog = React.useMemo(() => normalizeProviderCatalog(provider_id_catalog), [provider_id_catalog])
  const [providerRows, setProviderRows] = React.useState<ProviderRow[]>(() =>
    normalizeProviders(providers, providerCatalog),
  )
  const [aliasRows, setAliasRows] = React.useState<AliasRows>(() => normalizeAliases(alias_bindings))
  const [checks, setChecks] = React.useState<ChecksMap>({})
  const [serverErrors, setServerErrors] = React.useState<LLMError[]>([])
  const [checkingName, setCheckingName] = React.useState<string | null>(null)
  const [saving, setSaving] = React.useState(false)
  const [sheetOpen, setSheetOpen] = React.useState(false)
  const [editingIndex, setEditingIndex] = React.useState<number | null>(null)
  const [draft, setDraft] = React.useState<ProviderRow>(() => newProvider(providerCatalog))
  const [draftErrors, setDraftErrors] = React.useState<LLMError[]>([])

  const preparedProviders = React.useMemo(
    () => providerRows.map(provider => prepareProviderForSave(provider, providerCatalog)),
    [providerCatalog, providerRows],
  )
  const providerErrors = React.useMemo(
    () => validateProviders(preparedProviders, translate),
    [preparedProviders, translate],
  )
  const aliasErrors = React.useMemo(
    () => validateAliases(aliasRows, preparedProviders, translate),
    [aliasRows, preparedProviders, translate],
  )
  const canSave = preparedProviders.length > 0 && providerErrors.length === 0 && aliasErrors.length === 0 && !saving
  const inheritSources = React.useMemo<InheritSource[]>(
    () =>
      providerRows
        .map((row, index) => ({ ...row, name: preparedProviders[index]?.name || row.name }))
        .filter(row => row.id != null && row.name && row.secret_status?.api_key === "stored"),
    [providerRows, preparedProviders],
  )
  const liveDraftErrors = React.useMemo<LLMError[]>(() => {
    if (!sheetOpen) return []
    const prepared = prepareProviderForSave(draft, providerCatalog)
    if (!prepared.name) return []
    const taken = providerRows
      .filter((_row, index) => index !== editingIndex)
      .map(row => prepareProviderForSave(row, providerCatalog).name)
    if (!taken.includes(prepared.name)) return []
    return [
      {
        field: "name",
        message: translate("web.setup.llm.errors.duplicate_provider", {
          values: { name: prepared.name },
        }),
      },
    ]
  }, [draft, providerRows, providerCatalog, editingIndex, sheetOpen, translate])

  const openNewSheet = () => {
    setEditingIndex(null)
    setDraft(newProvider(providerCatalog))
    setDraftErrors([])
    setSheetOpen(true)
  }

  const openEditSheet = (index: number) => {
    setEditingIndex(index)
    setDraft(editableProvider(providerRows[index]))
    setDraftErrors([])
    setSheetOpen(true)
  }

  const applyDraft = () => {
    const prepared = prepareProviderForSave(draft, providerCatalog)
    const errors = validateProviderDraft(prepared, preparedProviders, editingIndex, translate)

    if (errors.length > 0) {
      setDraftErrors(errors)
      return
    }

    const previousName = editingIndex === null ? null : (providerRows[editingIndex]?.name ?? null)
    const nextProvider = providerFromPrepared(prepared, draft, providerCatalog)

    setProviderRows(current => {
      if (editingIndex === null) return [...current, nextProvider]

      return current.map((provider, index) => (index === editingIndex ? nextProvider : provider))
    })

    setAliasRows(current => retargetAliases(current, previousName, nextProvider.name))
    clearChecks([previousName, nextProvider.name])
    setServerErrors([])
    setSheetOpen(false)
  }

  const removeProvider = (index: number) => {
    const provider = providerRows[index]

    setProviderRows(current => current.filter((_provider, itemIndex) => itemIndex !== index))
    setAliasRows(current => removeAliasTargets(current, provider.name))
    clearChecks(provider.name)
    setServerErrors([])
  }

  const clearChecks = (names: string | Array<string | null | undefined>) => {
    const list = Array.isArray(names) ? names : [names]

    setChecks(current => {
      const next = { ...current }
      for (const name of list.filter((value): value is string => Boolean(value))) {
        delete next[name]
      }
      return next
    })
  }

  const runCheck = async (provider: ProviderRow | PreparedProvider) => {
    const prepared =
      "provider_options_error" in provider || "base_url" in provider || "api_key_inherits_from" in provider
        ? (provider as PreparedProvider)
        : prepareProviderForSave(provider as ProviderRow, providerCatalog)
    const errors = validateProvider(prepared, translate)

    if (errors.length > 0) {
      setServerErrors(errors)
      return
    }

    setCheckingName(prepared.name)
    setServerErrors([])

    const response = await postJson(check_path, { provider: cleanProviderPayload(prepared) })

    setCheckingName(null)

    if (response.redirect_to) {
      window.location.assign(response.redirect_to)
      return
    }

    if (!response.ok) {
      setChecks(current => ({
        ...current,
        [prepared.name]: { status: "error", errors: response.errors || [] },
      }))
      setServerErrors(response.errors || [])
      return
    }

    setChecks(current => ({
      ...current,
      [prepared.name]: {
        status: "success",
        result: response.result,
      },
    }))
  }

  const runDraftCheck = async () => {
    const prepared = prepareProviderForSave(draft, providerCatalog)
    const errors = validateProvider(prepared, translate)

    if (errors.length > 0) {
      setDraftErrors(errors)
      return
    }

    await runCheck(prepared)
  }

  const saveProviders = async () => {
    if (!canSave) return

    setSaving(true)
    setServerErrors([])

    const response = await postJson(save_path, {
      providers: preparedProviders.map(cleanProviderPayload),
      alias_bindings: aliasPayload(aliasRows),
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
    <SetupLayout title={translate("web.setup.llm.title")} appName={app_name}>
      <section className="grid flex-1 place-items-center py-8 sm:py-10">
        <Card size="sm" className="w-full max-w-5xl gap-0 bg-card py-0">
          <CardHeader className="border-b border-border px-5 py-4 sm:px-6">
            <div className="min-w-0">
              <p className="text-xs font-medium text-primary">{translate("web.setup.llm.step")}</p>
              <CardTitle className="mt-1 text-xl font-semibold">{translate("web.setup.llm.heading")}</CardTitle>
            </div>
          </CardHeader>

          <CardContent className="grid gap-8 px-5 py-5 sm:px-6">
            <ErrorList errors={[...providerErrors, ...aliasErrors, ...serverErrors]} />

            <section className="grid gap-4">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0">
                  <h2 className="text-sm font-semibold">{translate("web.setup.llm.providers.title")}</h2>
                  <p className="mt-1 text-sm text-muted-foreground">
                    {translate("web.setup.llm.providers.description")}
                  </p>
                </div>
                <Button type="button" onClick={openNewSheet}>
                  <RiAddLine data-icon="inline-start" />
                  <span>{translate("web.setup.llm.providers.add")}</span>
                </Button>
              </div>

              {providerRows.length === 0 ? (
                <EmptyProviders onAdd={openNewSheet} />
              ) : (
                <div className="grid gap-3">
                  {providerRows.map((provider, index) => (
                    <ProviderRowView
                      key={provider.id || `${provider.name || "provider"}-${index}`}
                      provider={provider}
                      providerCatalog={providerCatalog}
                      check={checks[provider.name]}
                      checking={checkingName === provider.name}
                      onCheck={() => runCheck(provider)}
                      onEdit={() => openEditSheet(index)}
                      onRemove={() => removeProvider(index)}
                    />
                  ))}
                </div>
              )}
            </section>

            <section className="grid gap-4">
              <div className="min-w-0">
                <h2 className="text-sm font-semibold">{translate("web.setup.llm.aliases.title")}</h2>
                <p className="mt-1 text-sm text-muted-foreground">{translate("web.setup.llm.aliases.description")}</p>
              </div>

              <div className="grid gap-3">
                {ALIASES.map(aliasName => (
                  <AliasRow
                    key={aliasName}
                    aliasName={aliasName}
                    binding={aliasRows[aliasName]}
                    providerNames={preparedProviders.map(provider => provider.name).filter(Boolean)}
                    onChange={binding =>
                      setAliasRows(current => ({
                        ...current,
                        [aliasName]: binding,
                      }))
                    }
                  />
                ))}
              </div>
            </section>
          </CardContent>

          <CardFooter className="justify-end border-t border-border px-5 py-4 sm:px-6">
            <Button type="button" onClick={saveProviders} disabled={!canSave}>
              <RiSaveLine data-icon="inline-start" />
              <span>{saving ? translate("web.setup.llm.saving") : translate("web.setup.llm.save")}</span>
            </Button>
          </CardFooter>
        </Card>
      </section>

      <ProviderSheet
        open={sheetOpen}
        onOpenChange={setSheetOpen}
        draft={draft}
        setDraft={next => {
          setDraft(next)
          setDraftErrors([])
        }}
        providerCatalogEntries={providerCatalog}
        inheritSources={inheritSources}
        errors={[...draftErrors, ...liveDraftErrors]}
        editing={editingIndex !== null}
        onApply={applyDraft}
        onTest={runDraftCheck}
        testing={checkingName === prepareProviderForSave(draft, providerCatalog).name}
      />
    </SetupLayout>
  )
}

interface ProviderRowViewProps {
  provider: ProviderRow
  providerCatalog: ProviderCatalogEntry[]
  check: CheckResult | undefined
  checking: boolean
  onCheck: () => void
  onEdit: () => void
  onRemove: () => void
}

function ProviderRowView({
  provider,
  providerCatalog,
  check,
  checking,
  onCheck,
  onEdit,
  onRemove,
}: ProviderRowViewProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const prepared = prepareProviderForSave(provider, providerCatalog)
  const invalid = validateProvider(prepared, translate).length > 0
  const apiKeySupported = providerApiKeySupported(prepared.provider_id, providerCatalog)
  const providerName =
    providerLabel(prepared.provider_id, providerCatalog, translate) || translate("web.setup.llm.fields.provider_id")
  const metadata = [
    prepared.model_id || translate("web.setup.llm.fields.model_id"),
    prepared.base_url ? translate("web.setup.llm.status.custom_base_url") : null,
  ].filter(Boolean)

  return (
    <div className="grid gap-4 border border-border bg-background-secondary p-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
      <div className="min-w-0">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <p className="min-w-0 truncate text-sm font-medium">
            {prepared.name || translate("web.setup.llm.providers.unnamed")}
          </p>
          {apiKeySupported ? <SecretBadge status={provider.secret_status?.api_key} /> : null}
        </div>
        <div className="mt-2 flex min-w-0 flex-wrap items-center gap-2 text-xs leading-5 text-muted-foreground">
          <Badge variant="outline">{providerName}</Badge>
          <span className="min-w-0 truncate">{metadata.join(" · ")}</span>
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-start gap-2 sm:justify-end">
        <CheckBadge invalid={invalid} checking={checking} check={check} />
        <Button type="button" size="sm" variant="outline" disabled={invalid || checking} onClick={onCheck}>
          <RiPlugLine data-icon="inline-start" />
          <span>{translate("web.setup.llm.actions.test")}</span>
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={translate("web.setup.llm.actions.edit")}
          onClick={onEdit}>
          <RiEditLine />
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={translate("web.setup.llm.actions.remove")}
          onClick={onRemove}>
          <RiDeleteBinLine />
        </Button>
      </div>
    </div>
  )
}

function EmptyProviders({ onAdd }: { onAdd: () => void }) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <div className="grid min-h-40 place-items-center border border-border bg-background-secondary px-4 py-10 text-center">
      <div className="grid justify-items-center gap-4">
        <div>
          <p className="text-base font-medium">{translate("web.setup.llm.providers.empty_title")}</p>
          <p className="mt-2 text-sm text-muted-foreground">{translate("web.setup.llm.providers.empty_description")}</p>
        </div>
        <Button type="button" onClick={onAdd}>
          <RiAddLine data-icon="inline-start" />
          <span>{translate("web.setup.llm.providers.add")}</span>
        </Button>
      </div>
    </div>
  )
}

interface AliasRowProps {
  aliasName: AliasName
  binding: AliasBinding | undefined
  providerNames: string[]
  onChange: (binding: AliasBinding) => void
}

function AliasRow({ aliasName, binding, providerNames, onChange }: AliasRowProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const providerOptions = providerNames.length ? providerNames : [""]
  const mode = aliasSelectMode(aliasName, binding)
  const target = binding?.target || ""

  const setMode = (nextMode: string | null) => {
    if (!nextMode) return

    if (nextMode.startsWith("alias:")) {
      onChange({ kind: "alias", target: nextMode.replace("alias:", "") })
      return
    }

    onChange({ kind: "provider", target: providerOptions[0] || "" })
  }

  return (
    <div className="grid gap-3 border border-border bg-background-secondary p-4 lg:grid-cols-[9rem_minmax(0,1fr)_minmax(11rem,14rem)_minmax(12rem,16rem)] lg:items-center">
      <div className="min-w-0">
        <p className="font-mono text-sm font-medium">:{aliasName}</p>
        <p className="mt-1 text-xs text-muted-foreground">{translate(`web.setup.llm.aliases.roles.${aliasName}`)}</p>
      </div>

      <div className="min-w-0 text-sm text-muted-foreground">{aliasSummary(aliasName, binding, translate)}</div>

      {aliasName === "default" ? (
        <div className="text-sm text-muted-foreground">{translate("web.setup.llm.aliases.provider_required")}</div>
      ) : (
        <Select value={mode} onValueChange={setMode}>
          <SelectTrigger className="w-full">
            <span data-slot="select-value">{aliasModeLabel(aliasName, mode, translate)}</span>
          </SelectTrigger>
          <SelectContent>
            {aliasTargetOptions(aliasName).map(targetAlias => (
              <SelectItem key={targetAlias} value={`alias:${targetAlias}`}>
                {aliasModeLabel(aliasName, `alias:${targetAlias}`, translate)}
              </SelectItem>
            ))}
            <SelectItem value="provider">{translate("web.setup.llm.aliases.modes.provider")}</SelectItem>
          </SelectContent>
        </Select>
      )}

      {mode === "provider" ? (
        <Select
          value={target}
          onValueChange={(value: string | null) => onChange({ kind: "provider", target: value ?? "" })}>
          <SelectTrigger className="w-full">
            <span data-slot="select-value">{target || translate("web.setup.llm.aliases.select_provider")}</span>
          </SelectTrigger>
          <SelectContent>
            {providerOptions.map(name => (
              <SelectItem key={name || "empty"} value={name}>
                {name || translate("web.setup.llm.aliases.no_provider")}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      ) : null}

      {mode.startsWith("alias:") ? (
        <div className="flex h-10 items-center border border-transparent border-b-input bg-field px-4 text-sm text-muted-foreground">
          {aliasTargetSummary(aliasName, translate, mode.replace("alias:", "") as AliasName)}
        </div>
      ) : null}
    </div>
  )
}

interface ProviderSheetProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  draft: ProviderRow
  setDraft: (next: ProviderRow) => void
  providerCatalogEntries: ProviderCatalogEntry[]
  inheritSources?: InheritSource[]
  errors: LLMError[]
  editing: boolean
  onApply: () => void
  onTest: () => void
  testing: boolean
}

function ProviderSheet({
  open,
  onOpenChange,
  draft,
  setDraft,
  providerCatalogEntries,
  inheritSources = [],
  errors,
  editing,
  onApply,
  onTest,
  testing,
}: ProviderSheetProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const [mode, setMode] = React.useState<"select" | "configure">(editing ? "configure" : "select")
  const [settingsOpen, setSettingsOpen] = React.useState(false)
  const fieldErrors = React.useMemo(() => errorsByField(errors), [errors])
  const formErrors = React.useMemo(() => errorsWithoutFields(errors), [errors])
  const catalogOptions: ProviderCatalogEntry[] = providerCatalogEntries.length
    ? providerCatalogEntries
    : normalizeProviderCatalog([draft.provider_id || "openai"])
  const catalogEntry = catalogEntryFor(catalogOptions, draft.provider_id) || catalogOptions[0]
  const providerOptionFields = catalogEntry?.provider_options || []
  const apiKeySupported = providerApiKeySupported(draft.provider_id, catalogOptions)
  const defaultName = endpointDefaultName(draft)

  React.useEffect(() => {
    if (!open) return

    setSettingsOpen(false)
    setMode(editing ? "configure" : "select")
  }, [editing, open])

  const update = <K extends keyof ProviderRow>(field: K, value: ProviderRow[K]) => {
    setDraft({ ...draft, [field]: value })
  }

  const updateProviderId = (providerId: string | null) => {
    if (!providerId) return
    const nextCatalogEntry = catalogEntryFor(catalogOptions, providerId)
    const nextApiKeySupported = providerApiKeySupported(providerId, catalogOptions)

    setDraft({
      ...draft,
      provider_id: providerId,
      provider_options: providerOptionDefaults(nextCatalogEntry),
      api_key_inherits_from: null,
      ...(nextApiKeySupported
        ? {}
        : {
            api_key: "",
            secret_status: { ...(draft.secret_status || {}), api_key: "missing" as SecretStatus },
          }),
    })
  }

  const updateProviderOption = (key: string, value: unknown) => {
    setDraft({
      ...draft,
      provider_options: {
        ...(draft.provider_options || {}),
        [key]: value,
      },
    })
  }

  const chooseProvider = (catalogItem: ProviderCatalogEntry) => {
    setDraft(newProviderForCatalogEntry(catalogItem))
    setMode("configure")
  }

  const chooseExistingSource = (source: InheritSource) => {
    setDraft(newProviderFromExistingSource(source))
    setMode("configure")
  }

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        className={[
          "top-1/2! right-1/2! bottom-auto! left-auto! max-w-none! translate-x-1/2! -translate-y-1/2! overflow-hidden border border-border",
          mode === "select"
            ? "h-auto! max-h-[min(42rem,calc(100vh-2rem))]! w-[min(48rem,calc(100vw-2rem))]!"
            : "h-[min(46rem,calc(100vh-2rem))]! w-[min(60rem,calc(100vw-2rem))]!",
        ].join(" ")}
        showCloseButton={false}>
        <SheetHeader className="shrink-0 border-b border-border px-5 py-4 sm:px-6">
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <SheetTitle>
                {mode === "select"
                  ? translate("web.setup.llm.sheet.select_title")
                  : editing
                    ? translate("web.setup.llm.sheet.edit_title")
                    : translate("web.setup.llm.sheet.add_title")}
              </SheetTitle>
              <SheetDescription>
                {mode === "select" ? (
                  ""
                ) : (
                  <>
                    {providerLabel(draft.provider_id, catalogOptions, translate) ||
                      translate("web.setup.llm.fields.provider_id")}
                    {" · "}
                    {draft.model_id || translate("web.setup.llm.fields.model_id")}
                  </>
                )}
              </SheetDescription>
            </div>
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              aria-label={translate("app.close")}
              onClick={() => onOpenChange(false)}>
              <RiCloseLine />
            </Button>
          </div>
        </SheetHeader>

        <div className="grid min-h-0 flex-1 gap-5 overflow-y-auto px-5 py-5 sm:px-6">
          {mode === "select" ? (
            <div className="grid gap-6">
              {inheritSources.length > 0 ? (
                <ExistingProvidersChooser
                  sources={inheritSources}
                  catalog={catalogOptions}
                  onChoose={chooseExistingSource}
                />
              ) : null}
              <div className="grid gap-3">
                {inheritSources.length > 0 ? (
                  <h3 className="text-sm font-semibold">{translate("web.setup.llm.sheet.choose_provider_type")}</h3>
                ) : null}
                <ProviderTypeChooser catalog={catalogOptions} onChoose={chooseProvider} />
              </div>
            </div>
          ) : (
            <>
              <ErrorList errors={formErrors} />

              <FormSection title={translate("web.setup.llm.sections.endpoint")}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field
                    label={translate("web.setup.llm.fields.name")}
                    required={Boolean(fieldErrors.name)}
                    error={fieldErrors.name}>
                    <Input
                      value={draft.name}
                      onChange={event => update("name", event.target.value)}
                      autoComplete="off"
                      placeholder={fieldErrors.name ? "" : defaultName}
                      aria-invalid={Boolean(fieldErrors.name) || undefined}
                      autoFocus
                    />
                  </Field>

                  <Field label={translate("web.setup.llm.fields.provider_id")} required error={fieldErrors.provider_id}>
                    <Select value={draft.provider_id} onValueChange={updateProviderId}>
                      <SelectTrigger className="w-full">
                        <span data-slot="select-value">
                          {providerLabel(draft.provider_id, catalogOptions, translate) ||
                            translate("web.setup.llm.fields.provider_id")}
                        </span>
                      </SelectTrigger>
                      <SelectContent>
                        {catalogOptions.map(item => (
                          <SelectItem key={item.id} value={item.id}>
                            {providerLabel(item.id, catalogOptions, translate)}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </Field>
                </div>
              </FormSection>

              <FormSection title={translate("web.setup.llm.sections.model")}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label={translate("web.setup.llm.fields.model_id")} required error={fieldErrors.model_id}>
                    <Input
                      value={draft.model_id}
                      onChange={event => update("model_id", event.target.value)}
                      autoComplete="off"
                      aria-invalid={Boolean(fieldErrors.model_id) || undefined}
                      required
                    />
                  </Field>
                </div>
              </FormSection>

              {apiKeySupported ? (
                <FormSection title={translate("web.setup.llm.sections.credentials")}>
                  <div className="grid gap-4">
                    <SecretField
                      label={translate("web.setup.llm.fields.api_key")}
                      value={draft.api_key || ""}
                      status={draft.secret_status?.api_key}
                      onChange={value => update("api_key", value)}
                    />
                    {draft.api_key_inherits_from && !draft.api_key?.trim() ? (
                      <p className="text-xs leading-5 text-primary">
                        {translate("web.setup.llm.fields.api_key_inherited", {
                          values: { source: draft.api_key_inherits_from },
                        })}
                      </p>
                    ) : null}
                    <p className="text-xs leading-5 text-muted-foreground">
                      {translate("web.setup.llm.fields.api_key_help")}
                    </p>
                  </div>
                </FormSection>
              ) : null}

              <Collapsible open={settingsOpen} onOpenChange={setSettingsOpen}>
                <FormSection
                  title={
                    <CollapsibleTrigger className="flex w-full cursor-pointer items-center justify-between gap-3 text-left">
                      <span>{translate("web.setup.llm.sections.advanced")}</span>
                      <RiArrowDownSLine
                        className={[
                          "size-4 shrink-0 text-muted-foreground transition-transform",
                          settingsOpen ? "rotate-180" : "",
                        ].join(" ")}
                      />
                    </CollapsibleTrigger>
                  }>
                  <CollapsibleContent>
                    <div className="grid gap-5 pt-1">
                      <div className="grid gap-4 md:grid-cols-2">
                        <Field label={translate("web.setup.llm.fields.base_url")}>
                          <Input
                            value={draft.base_url}
                            onChange={event => update("base_url", event.target.value)}
                            autoComplete="off"
                            placeholder={catalogEntry?.default_base_url || ""}
                          />
                        </Field>
                      </div>

                      {providerOptionFields.length > 0 ? (
                        <div className="grid gap-4 md:grid-cols-2">
                          {providerOptionFields.map(field => (
                            <ProviderOptionFieldView
                              key={field.key}
                              field={field}
                              value={draft.provider_options?.[field.key]}
                              onChange={value => updateProviderOption(field.key, value)}
                              error={fieldErrors[field.key]}
                            />
                          ))}
                        </div>
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
              {translate("web.setup.llm.sheet.cancel")}
            </Button>
            <Button type="button" variant="outline" onClick={onTest} disabled={testing}>
              <RiPlugLine data-icon="inline-start" />
              <span>
                {testing ? translate("web.setup.llm.status.checking") : translate("web.setup.llm.actions.test")}
              </span>
            </Button>
            <Button type="button" onClick={onApply}>
              {editing ? <RiSaveLine data-icon="inline-start" /> : <RiAddLine data-icon="inline-start" />}
              <span>
                {editing ? translate("web.setup.llm.sheet.save_changes") : translate("web.setup.llm.providers.add")}
              </span>
            </Button>
          </SheetFooter>
        ) : null}
      </SheetContent>
    </Sheet>
  )
}

interface ExistingProvidersChooserProps {
  sources: InheritSource[]
  catalog: ProviderCatalogEntry[]
  onChoose: (source: InheritSource) => void
}

function ExistingProvidersChooser({ sources, catalog, onChoose }: ExistingProvidersChooserProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const [open, setOpen] = React.useState(false)

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <CollapsibleTrigger className="flex w-full cursor-pointer items-center justify-between gap-3 border border-border bg-background-secondary px-4 py-3 text-left transition-colors hover:border-primary hover:bg-muted focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 focus-visible:outline-none">
        <span className="min-w-0">
          <span className="block text-sm font-semibold">{translate("web.setup.llm.sheet.from_existing_title")}</span>
          <span className="mt-0.5 block text-xs text-muted-foreground">
            {translate("web.setup.llm.sheet.from_existing_description")}
          </span>
        </span>
        <RiArrowDownSLine
          className={["size-4 shrink-0 text-muted-foreground transition-transform", open ? "rotate-180" : ""].join(" ")}
        />
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div
          className={[
            "mt-3 grid self-start gap-3",
            sources.length > 1 ? "sm:grid-cols-2" : "sm:grid-cols-[minmax(0,24rem)]",
          ].join(" ")}>
          {sources.map(source => (
            <button
              key={source.name}
              type="button"
              className="group grid min-h-20 gap-3 border border-border bg-background-secondary p-4 text-left transition-colors hover:border-primary hover:bg-muted focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 focus-visible:outline-none"
              onClick={() => onChoose(source)}>
              <span className="flex items-center justify-between gap-4">
                <span className="min-w-0 truncate text-sm font-semibold">{source.name}</span>
                <RiArrowRightSLine className="size-5 shrink-0 text-muted-foreground group-hover:text-primary" />
              </span>
              <span className="flex flex-wrap gap-2">
                <Badge variant="outline">
                  {providerLabel(source.provider_id, catalog, translate) || source.provider_id}
                </Badge>
                {source.model_id ? <Badge variant="outline">{source.model_id}</Badge> : null}
                <Badge variant="secondary">{translate("web.setup.llm.sheet.api_key_stored_badge")}</Badge>
              </span>
            </button>
          ))}
        </div>
      </CollapsibleContent>
    </Collapsible>
  )
}

interface ProviderTypeChooserProps {
  catalog: ProviderCatalogEntry[]
  onChoose: (catalogItem: ProviderCatalogEntry) => void
}

function ProviderTypeChooser({ catalog, onChoose }: ProviderTypeChooserProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <div
      className={[
        "grid self-start gap-3",
        catalog.length > 1 ? "sm:grid-cols-2" : "sm:grid-cols-[minmax(0,24rem)]",
      ].join(" ")}>
      {catalog.map(item => (
        <button
          key={item.id}
          type="button"
          className="group grid min-h-28 gap-4 border border-border bg-background-secondary p-4 text-left transition-colors hover:border-primary hover:bg-muted focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 focus-visible:outline-none"
          onClick={() => onChoose(item)}>
          <span className="flex items-center justify-between gap-4">
            <span className="min-w-0 truncate text-base font-semibold">
              {providerLabel(item.id, catalog, translate)}
            </span>
            <RiArrowRightSLine className="size-5 shrink-0 text-muted-foreground group-hover:text-primary" />
          </span>
          <span className="flex flex-wrap gap-2">
            <Badge variant="outline">{item.id}</Badge>
          </span>
        </button>
      ))}
    </div>
  )
}

interface ProviderOptionFieldViewProps {
  field: ProviderOptionField
  value: unknown
  onChange: (value: unknown) => void
  error?: string
}

function ProviderOptionFieldView({ field, value, onChange, error }: ProviderOptionFieldViewProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const label = providerOptionLabel(field, translate)
  const description = providerOptionDescription(field, translate)
  const effectiveValue = fieldValue(field, value)

  if (field.input_type === "boolean") {
    return (
      <div className="grid gap-2">
        <div className="flex items-start justify-between gap-4 border border-border bg-background-secondary p-4">
          <div className="min-w-0">
            <p className="text-sm font-medium">
              <span>{label}</span>
              {field.required ? (
                <span className="ml-1 text-xs font-normal text-muted-foreground">
                  {translate("web.setup.llm.required")}
                </span>
              ) : null}
            </p>
            {description ? (
              <p className="mt-1 line-clamp-3 text-xs leading-5 text-muted-foreground">{description}</p>
            ) : null}
            {error ? <p className="mt-2 text-xs text-destructive">{error}</p> : null}
          </div>
          <Switch checked={Boolean(effectiveValue)} onCheckedChange={onChange} aria-label={label} />
        </div>
      </div>
    )
  }

  if (field.input_type === "select") {
    return (
      <Field label={label} required={field.required} error={error}>
        <Select value={stringValue(effectiveValue)} onValueChange={onChange}>
          <SelectTrigger className="w-full">
            <span data-slot="select-value">
              {effectiveValue === undefined || effectiveValue === null || effectiveValue === ""
                ? translate("web.setup.llm.provider_settings.select_value")
                : providerOptionValueLabel(field, stringValue(effectiveValue), translate)}
            </span>
          </SelectTrigger>
          <SelectContent>
            {(field.options || []).map(option => (
              <SelectItem key={option} value={option}>
                {providerOptionValueLabel(field, option, translate)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  if (field.input_type === "json") {
    return (
      <div className="md:col-span-2">
        <Field label={label} required={field.required} error={error}>
          <ProviderOptionJsonEditor field={field} value={effectiveValue} onChange={onChange} />
          {description ? <FieldDescription>{description}</FieldDescription> : null}
        </Field>
      </div>
    )
  }

  return (
    <Field label={label} required={field.required} error={error}>
      <Input
        type={field.input_type === "integer" || field.input_type === "float" ? "number" : "text"}
        value={stringValue(effectiveValue)}
        onChange={event => onChange(event.target.value)}
        autoComplete="off"
        aria-invalid={Boolean(error) || undefined}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
  )
}

interface ProviderOptionJsonEditorProps {
  field: ProviderOptionField
  value: unknown
  onChange: (value: unknown) => void
}

function ProviderOptionJsonEditor({ field, value, onChange }: ProviderOptionJsonEditorProps) {
  const { t } = useTranslation()
  const translate = t as Translate
  const translations = React.useMemo(() => jsonEditorTranslations(translate), [translate])
  const canClear = value !== undefined && value !== null && value !== ""

  return (
    <div className="grid gap-2">
      <div className="flex items-center justify-end">
        <Button
          type="button"
          size="icon-xs"
          variant="ghost"
          disabled={!canClear}
          aria-label={translate("web.setup.llm.actions.clear")}
          title={translate("web.setup.llm.actions.clear")}
          onClick={() => onChange("")}>
          <RiCloseLine />
        </Button>
      </div>
      <JsonEditor
        data={jsonEditorData(value, field)}
        setData={onChange}
        rootName={field.key}
        theme={JSON_EDITOR_THEME}
        icons={JSON_EDITOR_ICONS}
        translations={translations}
        className="bullx-json-editor min-w-full"
        minWidth="100%"
        maxWidth="100%"
        rootFontSize="13px"
        indent={2}
        defaultValue={null}
        enableClipboard={false}
        showIconTooltips
        showCollectionCount="when-closed"
        showStringQuotes
      />
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
  required?: boolean
  error?: string
  children: React.ReactNode
}

function Field({ label, required, error, children }: FieldProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <div className="grid gap-2">
      <Label>
        <span>{label}</span>
        {required ? (
          <span className="ml-1 text-xs font-normal text-muted-foreground">{translate("web.setup.llm.required")}</span>
        ) : null}
      </Label>
      {children}
      {error ? <p className="text-xs text-destructive">{error}</p> : null}
    </div>
  )
}

function FieldDescription({ children }: { children: React.ReactNode }) {
  return <p className="line-clamp-3 text-xs leading-5 text-muted-foreground">{children}</p>
}

interface SecretFieldProps {
  label: string
  value: string
  status: SecretStatus | undefined
  onChange: (value: string) => void
}

function SecretField({ label, value, status, onChange }: SecretFieldProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  return (
    <Field label={label}>
      <div className="relative">
        <Input
          type="password"
          value={value}
          onChange={event => onChange(event.target.value)}
          autoComplete="new-password"
          placeholder={status === "stored" ? translate("web.setup.llm.secret_stored") : ""}
          className={status === "stored" ? "pr-24" : undefined}
        />
        {status === "stored" ? (
          <span className="absolute right-3 top-1/2 -translate-y-1/2">
            <Badge variant="secondary">{translate("web.setup.llm.secret_stored_badge")}</Badge>
          </span>
        ) : null}
      </div>
    </Field>
  )
}

function SecretBadge({ status }: { status: SecretStatus | undefined }) {
  const { t } = useTranslation()
  const translate = t as Translate

  if (status === "stored") {
    return <Badge variant="secondary">{translate("web.setup.llm.secret_stored_badge")}</Badge>
  }

  return <Badge variant="outline">{translate("web.setup.llm.status.no_key")}</Badge>
}

interface CheckBadgeProps {
  invalid: boolean
  checking: boolean
  check: CheckResult | undefined
}

function CheckBadge({ invalid, checking, check }: CheckBadgeProps) {
  const { t } = useTranslation()
  const translate = t as Translate

  if (invalid) return <Badge variant="destructive">{translate("web.setup.llm.status.invalid")}</Badge>
  if (checking) return <Badge variant="secondary">{translate("web.setup.llm.status.checking")}</Badge>

  if (check?.status === "success") {
    return (
      <Badge className="bg-green-20 text-green-70 hover:bg-green-30 dark:bg-green-80 dark:text-green-20 dark:hover:bg-green-70">
        <RiCheckboxCircleLine />
        <span>{translate("web.setup.llm.status.connected")}</span>
      </Badge>
    )
  }

  if (check?.status === "error") {
    return <Badge variant="destructive">{translate("web.setup.llm.status.failed")}</Badge>
  }

  return <Badge variant="outline">{translate("web.setup.llm.status.untested")}</Badge>
}

function ErrorList({ errors }: { errors: LLMError[] }) {
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

function normalizeProviderCatalog(
  catalog: Array<string | ProviderCatalogEntryInput> | undefined,
): ProviderCatalogEntry[] {
  return (catalog || [])
    .map((item): ProviderCatalogEntry => {
      if (typeof item === "string") {
        return {
          id: item,
          label: providerLabelFromId(item),
          default_base_url: "",
          api_key_supported: true,
          provider_options: [],
        }
      }

      const id = item.id || item.provider_id || ""

      return {
        id,
        label: item.label || providerLabelFromId(id),
        default_base_url: item.default_base_url || "",
        api_key_supported: item.api_key_supported !== false,
        provider_options: Array.isArray(item.provider_options) ? item.provider_options : [],
      }
    })
    .filter(item => item.id)
}

function normalizeProviders(providers: ProviderRowInput[], catalog: ProviderCatalogEntry[]): ProviderRow[] {
  return providers.map(provider =>
    editableProvider({
      ...provider,
      provider_id: provider.provider_id || catalog[0]?.id || "",
    }),
  )
}

function editableProvider(provider: ProviderRowInput): ProviderRow {
  const providerOptions = provider.provider_options || {}

  return {
    id: provider.id || null,
    name: provider.name || "",
    provider_id: provider.provider_id || "",
    model_id: provider.model_id || "",
    base_url: provider.base_url || "",
    api_key: provider.api_key || "",
    api_key_inherits_from: provider.api_key_inherits_from || null,
    provider_options: providerOptions,
    secret_status: provider.secret_status || { api_key: "missing" },
  }
}

function newProvider(catalog: ProviderCatalogEntry[]): ProviderRow {
  const normalized = catalog
  return newProviderForCatalogEntry(
    normalized[0] || { id: "", label: "", default_base_url: "", api_key_supported: true, provider_options: [] },
  )
}

function newProviderForCatalogEntry(catalogEntry: ProviderCatalogEntry | undefined): ProviderRow {
  return {
    id: null,
    name: "",
    provider_id: catalogEntry?.id || "",
    model_id: "",
    base_url: "",
    api_key: "",
    api_key_inherits_from: null,
    provider_options: providerOptionDefaults(catalogEntry),
    secret_status: { api_key: "missing" },
  }
}

function newProviderFromExistingSource(source: InheritSource): ProviderRow {
  return {
    id: null,
    name: "",
    provider_id: source.provider_id || "",
    model_id: source.model_id || "",
    base_url: source.base_url || "",
    api_key: "",
    api_key_inherits_from: source.name,
    provider_options: { ...(source.provider_options || {}) },
    secret_status: { api_key: "stored" },
  }
}

function providerFromPrepared(
  prepared: PreparedProvider,
  draft: ProviderRow,
  catalog: ProviderCatalogEntry[] = [],
): ProviderRow {
  const apiKeySupported = providerApiKeySupported(prepared.provider_id, catalog)
  const typedKey = apiKeySupported && typeof draft.api_key === "string" && draft.api_key.trim() !== ""
  const inheritsFrom = apiKeySupported && !typedKey && draft.api_key_inherits_from ? draft.api_key_inherits_from : null
  const apiKeyStatus: SecretStatus = apiKeySupported
    ? typedKey || inheritsFrom
      ? "stored"
      : draft.secret_status?.api_key || "missing"
    : "missing"

  return {
    id: draft.id || prepared.id || null,
    name: prepared.name,
    provider_id: prepared.provider_id,
    model_id: prepared.model_id,
    base_url: prepared.base_url || "",
    api_key: apiKeySupported ? draft.api_key || "" : "",
    api_key_inherits_from: inheritsFrom,
    provider_options: prepared.provider_options || {},
    secret_status: {
      api_key: apiKeyStatus,
    },
  }
}

function prepareProviderForSave(provider: ProviderRow, catalog: ProviderCatalogEntry[] = []): PreparedProvider {
  const options = parseProviderOptions(provider, catalog)
  const providerId = trimmed(provider.provider_id)
  const modelId = trimmed(provider.model_id)
  const apiKeySupported = providerApiKeySupported(providerId, catalog)
  const attrs: PreparedProvider = {
    id: provider.id || null,
    name: trimmed(provider.name) || endpointDefaultName({ provider_id: providerId, model_id: modelId }),
    provider_id: providerId,
    model_id: modelId,
    provider_options: options.ok ? options.value : {},
  }

  if (!options.ok) attrs.provider_options_error = options.error
  if (options.field_errors) attrs.provider_options_field_errors = options.field_errors
  if (trimmed(provider.base_url)) attrs.base_url = trimmed(provider.base_url)
  if (apiKeySupported && typeof provider.api_key === "string" && provider.api_key.trim()) {
    attrs.api_key = provider.api_key.trim()
  } else if (provider.api_key === null || !apiKeySupported) {
    attrs.api_key = null
  }
  if (apiKeySupported && provider.api_key_inherits_from && !("api_key" in attrs)) {
    attrs.api_key_inherits_from = provider.api_key_inherits_from
  }

  return attrs
}

function cleanProviderPayload(
  provider: PreparedProvider,
): Omit<PreparedProvider, "provider_options_error" | "provider_options_field_errors"> {
  const {
    provider_options_error: _providerOptionsError,
    provider_options_field_errors: _providerOptionsFieldErrors,
    ...payload
  } = provider

  return payload
}

type ParsedOptionsOk = { ok: true; value: Record<string, unknown>; field_errors?: undefined; error?: undefined }
type ParsedOptionsErr = {
  ok: false
  error: string
  field_errors?: Array<{ field: string; error: string }>
  value?: undefined
}
type ParsedOptions = ParsedOptionsOk | ParsedOptionsErr

function parseProviderOptions(provider: ProviderRow, catalog: ProviderCatalogEntry[] = []): ParsedOptions {
  const catalogEntry = catalogEntryFor(catalog, provider.provider_id)
  const fields = catalogEntry?.provider_options || []
  const values = provider.provider_options || {}
  const parsed: Record<string, unknown> = {}
  const errors: Array<{ field: string; error: string }> = []

  for (const field of fields) {
    const value = values[field.key]
    const result = parseProviderOptionField(field, value)

    if (!result.ok) {
      errors.push({ field: `provider_options.${field.key}`, error: result.error })
    } else if (result.hasValue) {
      parsed[field.key] = result.value
    }
  }

  if (errors.length > 0) {
    return { ok: false, error: "provider_options_invalid", field_errors: errors }
  }

  return { ok: true, value: parsed }
}

type ParsedFieldOk = { ok: true; hasValue: true; value: unknown } | { ok: true; hasValue: false }
type ParsedFieldErr = { ok: false; error: string }
type ParsedField = ParsedFieldOk | ParsedFieldErr

function parseProviderOptionField(field: ProviderOptionField, value: unknown): ParsedField {
  const effectiveValue = fieldValue(field, value)

  if (effectiveValue === undefined || effectiveValue === null || effectiveValue === "") {
    if (field.required) {
      return { ok: false, error: "provider_options_required" }
    }

    return { ok: true, hasValue: false }
  }

  if (field.input_type === "boolean") {
    if (typeof effectiveValue === "string") {
      return { ok: true, hasValue: true, value: effectiveValue.toLowerCase() === "true" }
    }

    return { ok: true, hasValue: true, value: Boolean(effectiveValue) }
  }

  if (field.input_type === "integer") {
    const number = Number(effectiveValue)
    return Number.isInteger(number)
      ? { ok: true, hasValue: true, value: number }
      : { ok: false, error: "provider_options_integer" }
  }

  if (field.input_type === "float") {
    const number = Number(effectiveValue)
    return Number.isFinite(number)
      ? { ok: true, hasValue: true, value: number }
      : { ok: false, error: "provider_options_float" }
  }

  if (field.input_type === "json") {
    return parseProviderOptionJsonField(effectiveValue)
  }

  return { ok: true, hasValue: true, value: String(effectiveValue).trim() }
}

function parseProviderOptionJsonField(value: unknown): ParsedField {
  if (isPlainObject(value) || Array.isArray(value) || typeof value === "boolean" || typeof value === "number") {
    return { ok: true, hasValue: true, value }
  }

  const text = String(value).trim()
  if (!text) return { ok: true, hasValue: false }

  try {
    return { ok: true, hasValue: true, value: JSON.parse(text) }
  } catch {
    return { ok: false, error: "provider_options_json" }
  }
}

function validateProviders(providers: PreparedProvider[], t: Translate): LLMError[] {
  const errors = providers.flatMap(provider => validateProvider(provider, t))
  const duplicate = duplicateName(providers)

  if (duplicate) {
    return [
      ...errors,
      {
        message: t("web.setup.llm.errors.duplicate_provider", {
          values: { name: duplicate },
        }),
      },
    ]
  }

  return errors
}

function validateProviderDraft(
  provider: PreparedProvider,
  providers: PreparedProvider[],
  editingIndex: number | null,
  t: Translate,
): LLMError[] {
  const otherProviders = providers.filter((_item, index) => index !== editingIndex)
  const errors = validateProvider(provider, t)
  const duplicate = otherProviders.some(item => item.name === provider.name)

  if (duplicate) {
    return [
      ...errors,
      {
        field: "name",
        message: t("web.setup.llm.errors.duplicate_provider", {
          values: { name: provider.name },
        }),
      },
    ]
  }

  return errors
}

function validateProvider(provider: PreparedProvider, t: Translate): LLMError[] {
  const errors: LLMError[] = []

  if (provider.name && !/^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,192}$/.test(provider.name)) {
    errors.push({ field: "name", message: t("web.setup.llm.errors.name_format") })
  }

  if (!provider.provider_id) {
    errors.push({ field: "provider_id", message: t("web.setup.llm.errors.provider_id_required") })
  }

  if (!provider.model_id) {
    errors.push({ field: "model_id", message: t("web.setup.llm.errors.model_id_required") })
  }

  if (provider.provider_options_error) {
    errors.push({
      field: "provider_options",
      message: t(`web.setup.llm.errors.${provider.provider_options_error}`),
    })
  }

  for (const error of provider.provider_options_field_errors || []) {
    errors.push({
      field: error.field,
      message: t(`web.setup.llm.errors.${error.error}`),
    })
  }

  return errors
}

function validateAliases(aliases: AliasRows, providers: PreparedProvider[], t: Translate): LLMError[] {
  const providerNames = new Set(providers.map(provider => provider.name).filter(Boolean))
  const defaultBinding = aliases.default
  const errors: LLMError[] = []
  const aliasGraph: Partial<Record<AliasName, AliasName | null>> = {}

  if (defaultBinding?.kind !== "provider" || !defaultBinding.target) {
    errors.push({ message: t("web.setup.llm.errors.default_required") })
  } else if (!providerNames.has(defaultBinding.target)) {
    errors.push({
      message: t("web.setup.llm.errors.default_unknown_provider", {
        values: { name: defaultBinding.target },
      }),
    })
  }

  for (const aliasName of ALIASES) {
    const binding = aliases[aliasName]

    if (binding?.kind === "provider") {
      aliasGraph[aliasName] = null

      if (binding.target && !providerNames.has(binding.target)) {
        errors.push({
          message: t("web.setup.llm.errors.alias_unknown_provider", {
            values: { alias: aliasName, name: binding.target },
          }),
        })
      }
    }

    if (binding?.kind === "alias") {
      const target = aliasTargetForBinding(aliasName, binding)

      if (aliasName === "default") {
        errors.push({ message: t("web.setup.llm.errors.default_alias_not_allowed") })
      } else if (!ALIASES.includes(target)) {
        errors.push({
          message: t("web.setup.llm.errors.alias_unknown", {
            values: { alias: aliasName, target },
          }),
        })
      } else {
        aliasGraph[aliasName] = target
      }
    }
  }

  const cycle = findAliasCycle(aliasGraph)
  if (cycle) {
    errors.push({
      message: t("web.setup.llm.errors.alias_cycle", {
        values: { path: cycle.map(item => `:${item}`).join(" → ") },
      }),
    })
  }

  return errors
}

function normalizeAliases(rows: AliasBinding[] | Record<string, AliasBinding> | undefined): AliasRows {
  const aliases: AliasRows = {
    default: { kind: "", target: "" },
    fast: { kind: "alias", target: "default" },
    heavy: { kind: "alias", target: "default" },
    compression: { kind: "alias", target: "fast" },
  }

  const list = Array.isArray(rows) ? rows : Object.values(rows || {})

  for (const row of list) {
    const aliasName = row.alias_name as AliasName | undefined
    if (!aliasName || !ALIASES.includes(aliasName)) continue

    if (row.kind === "provider") {
      aliases[aliasName] = { kind: "provider", target: row.target || "" }
    } else if (
      aliasName !== "default" &&
      (row.kind === "alias" ||
        row.kind === "default" ||
        row.source === "default_provider" ||
        row.source === "fallback_provider")
    ) {
      aliases[aliasName] = {
        kind: "alias",
        target: aliasTargetForBinding(aliasName, row),
      }
    }
  }

  return aliases
}

function aliasPayload(
  aliases: AliasRows,
): Record<AliasName, { kind: AliasBinding["kind"] | undefined; target: string | undefined }> {
  return Object.fromEntries(
    ALIASES.map(aliasName => {
      const binding = aliases[aliasName]

      if (aliasName !== "default" && binding?.kind === "alias") {
        return [
          aliasName,
          {
            kind: "alias",
            target: aliasTargetForBinding(aliasName, binding),
          },
        ]
      }

      return [aliasName, { kind: binding?.kind, target: binding?.target }]
    }),
  ) as Record<AliasName, { kind: AliasBinding["kind"] | undefined; target: string | undefined }>
}

function aliasSummary(aliasName: AliasName, binding: AliasBinding | undefined, t: Translate): string {
  if (binding?.kind === "provider" && binding.target) {
    return t("web.setup.llm.aliases.bound_provider", {
      values: { target: binding.target },
    })
  }

  if (aliasName !== "default") {
    return aliasTargetSummary(aliasName, t, aliasTargetForBinding(aliasName, binding))
  }

  return t("web.setup.llm.aliases.unbound")
}

function retargetAliases(aliases: AliasRows, previousName: string | null, nextName: string): AliasRows {
  if (!previousName || previousName === nextName) return aliases

  return Object.fromEntries(
    ALIASES.map(aliasName => {
      const binding = aliases[aliasName]

      if (binding?.kind === "provider" && binding.target === previousName) {
        return [aliasName, { ...binding, target: nextName }]
      }

      return [aliasName, binding]
    }),
  ) as AliasRows
}

function removeAliasTargets(aliases: AliasRows, removedName: string): AliasRows {
  return Object.fromEntries(
    ALIASES.map(aliasName => {
      const binding = aliases[aliasName]

      if (binding?.kind === "provider" && binding.target === removedName) {
        if (aliasName === "default") return [aliasName, { kind: "", target: "" }]
        return [aliasName, { kind: "alias", target: defaultAliasTarget(aliasName) }]
      }

      return [aliasName, binding]
    }),
  ) as AliasRows
}

function defaultAliasTarget(aliasName: AliasName): AliasName {
  return DEFAULT_ALIAS_TARGETS[aliasName] || "default"
}

function aliasTargetOptions(aliasName: AliasName): AliasName[] {
  if (aliasName === "default") return []
  return ALIASES.filter(item => item !== aliasName)
}

function aliasTargetForBinding(aliasName: AliasName, binding: AliasBinding | undefined): AliasName {
  const target = (binding?.target || defaultAliasTarget(aliasName)) as AliasName
  return aliasTargetOptions(aliasName).includes(target) ? target : defaultAliasTarget(aliasName)
}

function aliasTargetSummary(
  aliasName: AliasName,
  t: Translate,
  target: AliasName = defaultAliasTarget(aliasName),
): string {
  return t("web.setup.llm.aliases.fallback_provider", {
    values: { target },
  })
}

function aliasTargetModeLabel(
  aliasName: AliasName,
  t: Translate,
  target: AliasName = defaultAliasTarget(aliasName),
): string {
  return t("web.setup.llm.aliases.modes.fallback_provider", {
    values: { target },
  })
}

function aliasModeLabel(aliasName: AliasName, mode: string, t: Translate): string {
  if (mode.startsWith("alias:")) {
    return aliasTargetModeLabel(aliasName, t, mode.replace("alias:", "") as AliasName)
  }

  return t(`web.setup.llm.aliases.modes.${mode}`)
}

function aliasSelectMode(aliasName: AliasName, binding: AliasBinding | undefined): string {
  if (binding?.kind === "provider") return "provider"
  if (aliasName === "default") return "provider"
  return `alias:${aliasTargetForBinding(aliasName, binding)}`
}

function findAliasCycle(graph: Partial<Record<AliasName, AliasName | null>>): AliasName[] | null {
  const effectiveGraph: Partial<Record<AliasName, AliasName | null>> = {
    fast: "default",
    heavy: "default",
    compression: "fast",
    ...graph,
  }

  for (const aliasName of ALIASES) {
    const cycle = aliasCycleFrom(aliasName, effectiveGraph, [])
    if (cycle) return cycle
  }

  return null
}

function aliasCycleFrom(
  aliasName: AliasName,
  graph: Partial<Record<AliasName, AliasName | null>>,
  path: AliasName[],
): AliasName[] | null {
  if (path.includes(aliasName)) return [...path, aliasName]

  const target = graph[aliasName]
  if (!target) return null

  return aliasCycleFrom(target, graph, [...path, aliasName])
}

function catalogEntryFor(catalog: ProviderCatalogEntry[], providerId: string): ProviderCatalogEntry | undefined {
  return catalog.find(item => item.id === providerId)
}

function providerApiKeySupported(providerId: string, catalog: ProviderCatalogEntry[] = []): boolean {
  const catalogEntry = catalogEntryFor(catalog, providerId)
  return catalogEntry ? catalogEntry.api_key_supported : true
}

function endpointDefaultName(provider: { provider_id?: string; model_id?: string }): string {
  const providerId = trimmed(provider.provider_id)
  const modelId = trimmed(provider.model_id)

  if (!providerId || !modelId) return ""

  return `${providerId}/${modelId}`
}

function providerLabel(providerId: string, catalog: ProviderCatalogEntry[], t?: Translate): string {
  const id = catalogEntryFor(catalog, providerId)?.id || providerId
  if (!id) return ""

  const fallback = providerLabelFromId(id)
  return t ? t(`web.setup.llm.provider_catalog.${id}`, { defaultValue: fallback }) : fallback
}

function providerLabelFromId(providerId: string): string {
  if (!providerId) return ""

  return providerId[0].toUpperCase() + providerId.slice(1)
}

function providerOptionLabel(field: ProviderOptionField, t: Translate): string {
  const fallback = field.label || field.key
  return t(`web.setup.llm.provider_options.${field.key}.label`, { defaultValue: fallback })
}

function providerOptionDescription(field: ProviderOptionField, t: Translate): string {
  return t(`web.setup.llm.provider_options.${field.key}.description`, {
    defaultValue: field.doc || "",
  })
}

function providerOptionValueLabel(field: ProviderOptionField, value: string, t: Translate): string {
  return t(`web.setup.llm.provider_options.${field.key}.options.${value}`, {
    defaultValue: value,
  })
}

function providerOptionDefaults(catalogEntry: ProviderCatalogEntry | undefined): Record<string, unknown> {
  return Object.fromEntries(
    (catalogEntry?.provider_options || [])
      .filter(field => field.default !== undefined && field.default !== null)
      .map(field => [field.key, field.default]),
  )
}

function fieldValue(field: ProviderOptionField, value: unknown): unknown {
  if (value !== undefined && value !== null && value !== "") return value
  if (field.default !== undefined && field.default !== null) return field.default
  return value
}

function stringValue(value: unknown): string {
  if (value === undefined || value === null) return ""
  return String(value)
}

function jsonEditorData(value: unknown, field: ProviderOptionField): unknown {
  if (value === undefined || value === null || value === "") {
    return jsonEditorEmptyValue(field)
  }

  if (typeof value !== "string") return value

  try {
    return JSON.parse(value)
  } catch {
    return value
  }
}

function jsonEditorEmptyValue(field: ProviderOptionField): unknown {
  return field.type?.includes(":list") ? [] : {}
}

function jsonEditorTranslations(t: Translate): Record<string, string> {
  return {
    KEY_NEW: t("web.setup.llm.json_editor.key_new"),
    KEY_SELECT: t("web.setup.llm.json_editor.key_select"),
    NO_KEY_OPTIONS: t("web.setup.llm.json_editor.no_key_options"),
    ERROR_KEY_EXISTS: t("web.setup.llm.json_editor.key_exists"),
    ERROR_INVALID_JSON: t("web.setup.llm.json_editor.invalid_json"),
    ERROR_UPDATE: t("web.setup.llm.json_editor.update_failed"),
    ERROR_DELETE: t("web.setup.llm.json_editor.delete_failed"),
    ERROR_ADD: t("web.setup.llm.json_editor.add_failed"),
    DEFAULT_STRING: t("web.setup.llm.json_editor.default_string"),
    DEFAULT_NEW_KEY: t("web.setup.llm.json_editor.default_key"),
    SHOW_LESS: t("web.setup.llm.json_editor.show_less"),
    EMPTY_STRING: t("web.setup.llm.json_editor.empty_string"),
    TOOLTIP_COPY: t("web.setup.llm.json_editor.copy"),
    TOOLTIP_EDIT: t("web.setup.llm.json_editor.edit"),
    TOOLTIP_DELETE: t("web.setup.llm.json_editor.delete"),
    TOOLTIP_ADD: t("web.setup.llm.json_editor.add"),
  }
}

function duplicateName(providers: PreparedProvider[]): string | null {
  const seen = new Set<string>()

  for (const provider of providers) {
    if (!provider.name) continue
    if (seen.has(provider.name)) return provider.name
    seen.add(provider.name)
  }

  return null
}

function errorsByField(errors: LLMError[]): Record<string, string> {
  return errors.reduce<Record<string, string>>((fields, error) => {
    const field = errorField(error)
    if (field && !fields[field]) fields[field] = error.message
    return fields
  }, {})
}

function errorsWithoutFields(errors: LLMError[]): LLMError[] {
  return errors.filter(error => !errorField(error))
}

function errorField(error: LLMError): string | undefined {
  const field = error.field || error.details?.field || error.details?.field_path
  if (!field) return undefined

  return field.split(".").at(-1)
}

function trimmed(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
