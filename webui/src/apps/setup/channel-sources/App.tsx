import { RiArrowRightSLine } from "@remixicon/react"
import { useEffect, useMemo, useState } from "react"
import { useForm as useHookForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import {
  Button,
  ErrorAlert,
  FieldGrid,
  InfoAlert,
  postJson,
  SetupPage,
  SetupPanel,
  submitInertia,
  TextField,
} from "../shared"

type SourceForm = {
  adapter_id: string
  source: Record<string, any>
}

function formDefaults(adapter?: Record<string, any>): SourceForm {
  const source = adapter?.projection?.sources?.[0] || adapter?.form_schema?.default_source || {}
  const sourceDefaults = { ...source }

  for (const field of schemaFields(adapter)) {
    if (field.kind === "secret") setPath(sourceDefaults, field.path.slice(1), "")
  }

  return {
    adapter_id: adapter?.id || "",
    source: sourceDefaults,
  }
}

function schemaFields(adapter: Record<string, any> | undefined) {
  return adapter?.form_schema?.sections?.flatMap((section: Record<string, any>) => section.fields || []) || []
}

function schemaOptions(field: Record<string, any>, fallback: string[]) {
  return field.options || fallback
}

function pathEquals(left: string[], right: string[]) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function fieldName(field: Record<string, any>) {
  return field.path.join(".")
}

function getPath(value: Record<string, any>, path: string[]) {
  return path.reduce((acc, key) => (acc && typeof acc === "object" ? acc[key] : undefined), value)
}

function setPath(value: Record<string, any>, path: string[], nextValue: any) {
  let cursor = value

  path.forEach((key, index) => {
    if (index === path.length - 1) {
      cursor[key] = nextValue
      return
    }

    cursor[key] = cursor[key] && typeof cursor[key] === "object" ? { ...cursor[key] } : {}
    cursor = cursor[key]
  })
}

function labelKey(field: Record<string, any>) {
  const path = field.path || []

  if (pathEquals(path, ["source", "id"])) {
    return "setup.channel_sources.source_id_label"
  }

  const key = path[path.length - 1]

  const labels: Record<string, string> = {
    app_id: "setup.channel_sources.app_id_label",
    app_secret: "setup.channel_sources.app_secret_label",
    application_id: "setup.channel_sources.application_id_label",
    bot_token: "setup.channel_sources.bot_token_label",
    bot_username: "setup.channel_sources.bot_username_label",
    callback_url: "setup.channel_sources.callback_url_label",
    client_secret: "setup.channel_sources.client_secret_label",
    domain: "setup.channel_sources.domain_label",
    enabled: "setup.channel_sources.enabled_label",
    group_message_mode: "setup.channel_sources.group_message_mode_label",
    redirect_uri: "setup.channel_sources.oauth_redirect_label",
    start_transport: "setup.channel_sources.start_transport_label",
    web_login_disabled: "setup.channel_sources.web_login_disabled_label",
  }

  if (pathEquals(path, ["source", "oidc", "enabled"]) || pathEquals(path, ["source", "oauth2", "enabled"])) {
    return "setup.channel_sources.oauth_enabled_label"
  }

  return labels[key] || key
}

function secretPlaceholder(source: Record<string, any>, field: Record<string, any>, fallback: string) {
  const status = getPath(source, field.path.slice(1))
  return status?.present ? fallback : ""
}

function secretPresent(source: Record<string, any>, field: Record<string, any>) {
  const status = getPath(source, field.path.slice(1))
  return status?.present === true
}

function optionLabelKey(field: Record<string, any>, option: string) {
  return pathEquals(field.path || [], ["source", "group_message_mode"])
    ? `setup.channel_sources.group_message_modes.${option}`
    : option
}

export default function SetupChannelSourcesApp({
  app_name = "BullX",
  adapters = [],
  ready_sources = [],
  oidc_callback_url_template,
  form_action,
  check_path,
  back_path,
  error,
}: {
  app_name?: string
  adapters: Array<Record<string, any>>
  ready_sources: Array<Record<string, any>>
  oidc_callback_url_template?: string
  form_action: string
  check_path: string
  back_path: string
  error?: unknown
}) {
  const { t } = useTranslation()
  const [selectedAdapterId, setSelectedAdapterId] = useState(adapters[0]?.id || "")
  const adapter = useMemo(
    () => adapters.find(item => item.id === selectedAdapterId) || adapters[0],
    [adapters, selectedAdapterId],
  )
  const source = adapter?.projection?.sources?.[0] || adapter?.form_schema?.default_source || {}
  const fields = schemaFields(adapter)
  const sourceIdField = fields.find((field: Record<string, any>) => pathEquals(field.path, ["source", "id"]))
  const credentialFields = fields.filter((field: Record<string, any>) => field.ui?.group === "credentials")
  const regularFields = fields.filter(
    (field: Record<string, any>) => !pathEquals(field.path, ["source", "id"]) && field.ui?.group !== "credentials",
  )
  const [operationResult, setOperationResult] = useState<unknown>()
  const { register, handleSubmit, getValues, reset, watch } = useHookForm<SourceForm>({
    defaultValues: formDefaults(adapter),
  })
  const watchedSourceId = watch("source.id")
  const watchedSource = watch("source")

  useEffect(() => {
    reset(formDefaults(adapter))
  }, [adapter, reset])

  async function checkSource() {
    const result = await postJson(check_path, getValues())
    setOperationResult(result)
  }

  function renderField(field: Record<string, any>) {
    const label = t(labelKey(field))
    const name = fieldName(field)

    if (field.kind === "callback_url") {
      if (!callbackEnabled(watchedSource, field)) return null

      return (
        <TextField
          key={name}
          label={label}
          readOnly
          value={callbackUrl(oidc_callback_url_template, watchedSourceId)}
          description={t("setup.channel_sources.callback_url_description")}
        />
      )
    }

    if (field.kind === "select") {
      return (
        <label key={name} className="flex flex-col gap-2 text-sm">
          <span className="font-semibold uppercase">{label}</span>
          <select className="h-10 border border-input bg-field px-3" {...register(name as any)}>
            {schemaOptions(field, []).map((option: string) => (
              <option key={option} value={option}>
                {t(optionLabelKey(field, option), { defaultValue: option })}
              </option>
            ))}
          </select>
        </label>
      )
    }

    if (field.kind === "boolean") {
      return (
        <label key={name} className="flex items-center gap-3 text-sm">
          <input type="checkbox" className="size-4" {...register(name as any)} />
          {label}
        </label>
      )
    }

    const isSavedSecret = field.kind === "secret" && secretPresent(source, field)

    return (
      <TextField
        key={name}
        label={label}
        type={field.kind === "secret" ? "password" : "text"}
        required={field.required === true && !isSavedSecret}
        placeholder={
          field.kind === "secret"
            ? secretPlaceholder(source, field, t("setup.channel_sources.secret_saved_hint"))
            : undefined
        }
        {...register(name as any)}
      />
    )
  }

  return (
    <SetupPage title={t("setup.channel_sources.page_title")} appName={app_name} step="channel_sources">
      <SetupPanel
        title={t("setup.channel_sources.panel_title")}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => window.location.assign(back_path)}>
              {t("setup.back")}
            </Button>
            {adapters.length ? (
              <Button type="submit" form="setup-source-form">
                {t("setup.channel_sources.save_button")}
                <RiArrowRightSLine data-icon="inline-end" />
              </Button>
            ) : null}
          </>
        }>
        <ErrorAlert error={error} />
        {adapters.length ? null : (
          <InfoAlert title={t("setup.channel_sources.no_adapter_title")}>
            {t("setup.channel_sources.no_adapter_body")}
          </InfoAlert>
        )}
        {ready_sources.length ? (
          <InfoAlert title={t("setup.channel_sources.runtime_ready_label")}>{JSON.stringify(ready_sources)}</InfoAlert>
        ) : null}
        {operationResult ? (
          <InfoAlert title={t("setup.channel_sources.operation_result_label")}>
            {JSON.stringify(operationResult)}
          </InfoAlert>
        ) : null}
        {adapters.length ? (
          <form
            id="setup-source-form"
            className="flex flex-col gap-5"
            onSubmit={handleSubmit(data => submitInertia(form_action, data as any))}>
            <input type="hidden" {...register("adapter_id")} />
            <FieldGrid>
              <label className="flex flex-col gap-2 text-sm">
                <span className="font-semibold uppercase">{t("setup.channel_sources.adapter_label")}</span>
                <select
                  className="h-10 border border-input bg-field px-3"
                  value={selectedAdapterId}
                  onChange={event => setSelectedAdapterId(event.target.value)}>
                  {adapters.map(item => (
                    <option key={item.id} value={item.id}>
                      {item.form_schema?.label || item.id}
                    </option>
                  ))}
                </select>
              </label>
              {sourceIdField ? renderField(sourceIdField) : null}
              {credentialFields.length ? (
                <div className="grid gap-5 md:col-span-2 md:grid-cols-2">{credentialFields.map(renderField)}</div>
              ) : null}
              <div className="md:col-span-2">
                <Button type="button" variant="outline" onClick={checkSource}>
                  {t("setup.channel_sources.check_button")}
                </Button>
              </div>
              {regularFields.map(renderField)}
            </FieldGrid>
          </form>
        ) : null}
      </SetupPanel>
    </SetupPage>
  )
}

function callbackUrl(template: string | undefined, sourceId: unknown) {
  const id = typeof sourceId === "string" ? sourceId.trim() : ""
  if (!template || !id) return ""
  return template.replace("__source_id__", encodeURIComponent(id))
}

function callbackEnabled(source: Record<string, any> | undefined, field: Record<string, any>) {
  const [, providerKey] = field.path || []
  const enabled = source?.[providerKey]?.enabled
  return enabled !== false
}
