import { RiArrowRightSLine } from "@remixicon/react"
import type React from "react"
import { useEffect, useRef, useState } from "react"
import type { UseFormReturn } from "react-hook-form"
import { useForm as useHookForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { JsonListInput, SelectListInput, StringListInput } from "@/uikit/components/list-input"
import {
  Button,
  ErrorAlert,
  FieldGrid,
  InfoAlert,
  postJson,
  SetupPage,
  SetupPanel,
  submitInertia,
  TextAreaField,
  TextField,
} from "../shared"

type OptionField = {
  key: string
  label: string
  input_type:
    | "boolean"
    | "integer"
    | "float"
    | "string"
    | "select"
    | "string_list"
    | "select_list"
    | "json_list"
    | "json"
  options: string[]
  required: boolean
  default: unknown
  doc: string
}

type CatalogEntry = {
  id: string
  label_key?: string
  default_base_url: string | null
  api_key_supported: boolean
  provider_options: OptionField[]
}

type ApiKeyStatus = { present?: boolean; masked?: string | null }

type ProviderDraft = {
  provider_id: string
  req_llm_provider: string
  base_url: string
  api_key: string
  test_model_id: string
  provider_options: Record<string, unknown>
}

type CheckResult =
  | { ok: true; result?: { ping?: { status?: string; text_preview?: string } } }
  | { ok: false; errors?: Array<{ message?: string; details?: unknown }> }

export default function SetupLLMApp({
  app_name = "BullX",
  providers = [],
  provider_catalog = [],
  form_action,
  check_path,
  back_path,
  error,
}: {
  app_name?: string
  providers: Array<Record<string, any>>
  provider_catalog: CatalogEntry[]
  form_action: string
  check_path: string
  back_path: string
  error?: unknown
}) {
  const { t } = useTranslation()
  const first = providers[0]
  const apiKeyStatus: ApiKeyStatus | undefined = first?.api_key
  const initialReq = first?.req_llm_provider || provider_catalog[0]?.id || ""
  const initialCatalog = findCatalog(provider_catalog, initialReq)
  const initialOptions = mergeOptionDefaults(initialCatalog, first?.provider_options)

  const form = useHookForm<ProviderDraft>({
    defaultValues: {
      provider_id: first?.provider_id || initialReq,
      req_llm_provider: initialReq,
      base_url: first?.base_url || initialCatalog?.default_base_url || "",
      api_key: "",
      test_model_id: "",
      provider_options: initialOptions,
    },
  })
  const { register, handleSubmit, getValues, setValue, watch } = form

  const reqProvider = watch("req_llm_provider")
  const currentCatalog = findCatalog(provider_catalog, reqProvider)

  // Track auto-derived defaults so we only override fields the user hasn't customized.
  const derivedRef = useRef({
    provider_id: initialReq,
    base_url: initialCatalog?.default_base_url || "",
  })

  useEffect(() => {
    if (!currentCatalog) return

    const nextProviderId = currentCatalog.id
    const nextBaseUrl = currentCatalog.default_base_url || ""

    if (getValues("provider_id") === derivedRef.current.provider_id) {
      setValue("provider_id", nextProviderId)
    }
    if (getValues("base_url") === derivedRef.current.base_url) {
      setValue("base_url", nextBaseUrl)
    }
    setValue("provider_options", mergeOptionDefaults(currentCatalog))

    derivedRef.current = { provider_id: nextProviderId, base_url: nextBaseUrl }
  }, [currentCatalog, getValues, setValue])

  const [checking, setChecking] = useState(false)
  const [checkResult, setCheckResult] = useState<CheckResult | null>(null)

  async function runCheck() {
    setChecking(true)
    setCheckResult(null)
    try {
      const payload = toPayload(getValues(), currentCatalog)
      const response = await postJson(check_path, { provider: payload })
      setCheckResult(response as CheckResult)
    } catch (err) {
      setCheckResult({ ok: false, errors: [{ message: String(err), details: err }] })
    } finally {
      setChecking(false)
    }
  }

  const apiKeyHint = apiKeyStatus?.present ? t("setup.llm.api_key_saved_hint") : undefined
  const apiKeyPlaceholder = apiKeyStatus?.present ? apiKeyStatus.masked || "••••••" : undefined

  return (
    <SetupPage title={t("setup.llm.page_title")} appName={app_name} step="llm_providers">
      <SetupPanel
        title={t("setup.llm.panel_title")}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => window.location.assign(back_path)}>
              {t("setup.back")}
            </Button>
            <Button type="submit" form="setup-llm-form">
              {t("setup.llm.save_button")}
              <RiArrowRightSLine data-icon="inline-end" />
            </Button>
          </>
        }>
        <ErrorAlert error={error} />
        {provider_catalog.length === 0 ? (
          <InfoAlert title={t("setup.llm.empty_catalog_title")}>{t("setup.llm.empty_catalog_body")}</InfoAlert>
        ) : null}

        <form
          id="setup-llm-form"
          className="flex flex-col gap-6"
          onSubmit={handleSubmit(draft =>
            submitInertia(form_action, { providers: [toPayload(draft, currentCatalog)] }),
          )}>
          <FieldGrid>
            <label className="flex flex-col gap-2 text-sm">
              <span className="font-semibold uppercase">{t("setup.llm.req_llm_provider_label")}</span>
              <select className="h-10 border border-input bg-field px-3" {...register("req_llm_provider")}>
                {provider_catalog.map(entry => (
                  <option key={entry.id} value={entry.id}>
                    {providerLabel(entry, t)}
                  </option>
                ))}
              </select>
            </label>
            <TextField
              label={t("setup.llm.provider_id_label")}
              description={t("setup.llm.provider_id_description")}
              {...register("provider_id")}
            />
          </FieldGrid>

          <div className="flex flex-col gap-4 border border-border/70 bg-card/40 p-4">
            <p className="text-xs font-semibold uppercase text-muted-foreground">{t("setup.llm.connection_label")}</p>
            <FieldGrid>
              <TextField
                label={t("setup.llm.base_url_label")}
                placeholder={currentCatalog?.default_base_url || ""}
                description={
                  currentCatalog?.default_base_url
                    ? t("setup.llm.base_url_default_description", { values: { url: currentCatalog.default_base_url } })
                    : undefined
                }
                {...register("base_url")}
              />
              {currentCatalog?.api_key_supported ? (
                <TextField
                  label={t("setup.llm.api_key_label")}
                  type="password"
                  placeholder={apiKeyPlaceholder}
                  description={apiKeyHint}
                  {...register("api_key")}
                />
              ) : null}
              <TextField
                label={t("setup.llm.test_model_id_label")}
                description={t("setup.llm.test_model_id_description")}
                {...register("test_model_id")}
              />
            </FieldGrid>
            <div className="flex flex-wrap items-center gap-3">
              <Button type="button" variant="outline" size="sm" onClick={runCheck} disabled={checking}>
                {checking ? t("setup.llm.test_button_loading") : t("setup.llm.test_button")}
              </Button>
              <CheckBadge result={checkResult} checking={checking} />
            </div>
          </div>

          {currentCatalog && currentCatalog.provider_options.length > 0 ? (
            <div className="flex flex-col gap-3">
              <p className="text-xs font-semibold uppercase text-muted-foreground">
                {t("setup.llm.provider_options_label")}
              </p>
              <FieldGrid>
                {currentCatalog.provider_options.map(field => (
                  <ProviderOptionInput key={field.key} field={field} form={form} />
                ))}
              </FieldGrid>
            </div>
          ) : null}
        </form>
      </SetupPanel>
    </SetupPage>
  )
}

function CheckBadge({ result, checking }: { result: CheckResult | null; checking: boolean }) {
  const { t } = useTranslation()
  if (checking || !result) return null

  if (result.ok) {
    const ping = result.result?.ping
    const status = ping?.status || "ok"
    const preview = ping?.text_preview
    const text = preview
      ? t("setup.llm.check_ok_with_preview", { values: { status, preview } })
      : t("setup.llm.check_ok", { values: { status } })
    return <span className="text-xs text-muted-foreground">{text}</span>
  }

  const message = result.errors?.[0]?.message || t("setup.llm.check_failed")
  return <span className="text-xs text-destructive">{message}</span>
}

function ProviderOptionInput({ field, form }: { field: OptionField; form: UseFormReturn<ProviderDraft> }) {
  const { t } = useTranslation()
  const name = `provider_options.${field.key}` as const
  const label = field.required ? `${field.label} *` : field.label
  const description = field.doc || undefined
  const { register, setValue, watch } = form

  switch (field.input_type) {
    case "boolean":
      return (
        <label className="flex items-center gap-3 text-sm">
          <input type="checkbox" className="size-4" {...register(name)} />
          <span>
            <span className="block font-semibold">{label}</span>
            {description ? <span className="block text-xs text-muted-foreground">{description}</span> : null}
          </span>
        </label>
      )

    case "integer":
      return <TextField label={label} type="number" step="1" description={description} {...register(name)} />

    case "float":
      return <TextField label={label} type="number" step="any" description={description} {...register(name)} />

    case "select":
      return (
        <label className="flex flex-col gap-2 text-sm">
          <span className="font-semibold uppercase">{label}</span>
          <select className="h-10 border border-input bg-field px-3" {...register(name)}>
            <option value="">—</option>
            {field.options.map(option => (
              <option key={option} value={option}>
                {option}
              </option>
            ))}
          </select>
          {description ? <span className="text-xs text-muted-foreground">{description}</span> : null}
        </label>
      )

    case "string_list":
      return (
        <ListField label={label} description={description}>
          <StringListInput
            value={stringArrayValue(watch(name))}
            placeholder={label}
            addLabel={t("setup.llm.list_add")}
            removeLabel={t("setup.llm.list_remove")}
            onValueChange={value => setValue(name, value, { shouldDirty: true, shouldTouch: true })}
          />
        </ListField>
      )

    case "select_list":
      return (
        <ListField label={label} description={description}>
          <SelectListInput
            value={stringArrayValue(watch(name))}
            options={field.options.map(option => ({ value: option }))}
            placeholder={label}
            emptyLabel={t("setup.llm.list_empty")}
            onValueChange={value => setValue(name, value, { shouldDirty: true, shouldTouch: true })}
          />
        </ListField>
      )

    case "json_list":
      return (
        <ListField label={label} description={description}>
          <JsonListInput
            value={arrayValue(watch(name))}
            addLabel={t("setup.llm.list_add_item")}
            removeLabel={t("setup.llm.list_remove_item")}
            onValueChange={value => setValue(name, value, { shouldDirty: true, shouldTouch: true })}
          />
        </ListField>
      )

    case "json":
      return <TextAreaField label={label} rows={4} description={description} {...register(name)} />

    default:
      return <TextField label={label} description={description} {...register(name)} />
  }
}

function ListField({
  label,
  description,
  children,
}: {
  label: string
  description?: string
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-col gap-2 text-sm">
      <span className="font-semibold uppercase">{label}</span>
      {children}
      {description ? <span className="text-xs text-muted-foreground">{description}</span> : null}
    </div>
  )
}

function findCatalog(catalog: CatalogEntry[], id: string | undefined | null) {
  if (!id) return undefined
  return catalog.find(entry => entry.id === id)
}

function providerLabel(entry: CatalogEntry, t: (key: string, options?: Record<string, unknown>) => string) {
  return entry.label_key ? t(entry.label_key, { defaultValue: entry.id }) : entry.id
}

function mergeOptionDefaults(catalog: CatalogEntry | undefined, persisted?: Record<string, unknown>) {
  const result: Record<string, unknown> = {}
  if (catalog) {
    for (const field of catalog.provider_options) {
      result[field.key] = toFormValue(field.default, field.input_type)
    }
  }
  if (persisted) {
    for (const [key, value] of Object.entries(persisted)) {
      result[key] = toFormValue(value, catalog?.provider_options.find(f => f.key === key)?.input_type)
    }
  }
  return result
}

function toFormValue(value: unknown, inputType?: OptionField["input_type"]) {
  if (value === undefined || value === null) return inputType === "boolean" ? false : ""
  if (inputType === "boolean") return Boolean(value)
  if (inputType === "string_list" || inputType === "select_list") return stringArrayValue(value)
  if (inputType === "json_list") return arrayValue(value)
  if (inputType === "json" && typeof value !== "string") return JSON.stringify(value, null, 2)
  return value
}

function toPayload(draft: ProviderDraft, catalog: CatalogEntry | undefined) {
  const options: Record<string, unknown> = {}
  if (catalog) {
    for (const field of catalog.provider_options) {
      const raw = draft.provider_options?.[field.key]
      const coerced = coerceOptionValue(raw, field.input_type)
      if (coerced !== undefined) options[field.key] = coerced
    }
  }

  return {
    provider_id: draft.provider_id,
    req_llm_provider: draft.req_llm_provider,
    base_url: draft.base_url,
    api_key: draft.api_key,
    test_model_id: draft.test_model_id,
    provider_options: options,
  }
}

function coerceOptionValue(value: unknown, type: OptionField["input_type"]) {
  if (type === "boolean") return Boolean(value)
  if (value === undefined || value === null || value === "") return undefined
  if (type === "string_list" || type === "select_list") {
    const values = stringArrayValue(value)
    return values.length > 0 ? values : undefined
  }
  if (type === "json_list") {
    const values = arrayValue(value)
    return values.length > 0 ? values : undefined
  }

  if (typeof value !== "string") return value

  switch (type) {
    case "integer": {
      const n = Number.parseInt(value, 10)
      return Number.isNaN(n) ? value : n
    }
    case "float": {
      const n = Number.parseFloat(value)
      return Number.isNaN(n) ? value : n
    }
    case "json": {
      try {
        return JSON.parse(value)
      } catch {
        return value
      }
    }
    default:
      return value
  }
}

function arrayValue(value: unknown) {
  return Array.isArray(value) ? value : []
}

function stringArrayValue(value: unknown) {
  if (!Array.isArray(value)) return []

  return value
    .map(item => (typeof item === "string" ? item : String(item)))
    .map(item => item.trim())
    .filter(Boolean)
}
