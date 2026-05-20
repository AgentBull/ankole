import { RiArrowRightSLine } from "@remixicon/react"
import { useForm as useHookForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Button, ErrorAlert, InfoAlert, SetupPage, SetupPanel, submitInertia } from "../shared"

type Plugin = {
  id: string
  app: string
  enabled?: boolean
  metadata?: PluginMetadata
}

type LocalizedText = string | Record<string, string>

type PluginMetadata = {
  display_name?: LocalizedText
  description?: LocalizedText
}

type PluginForm = {
  plugins: string[]
}

export default function SetupPluginsApp({
  app_name = "BullX",
  plugins = [],
  persisted_enabled_ids = [],
  runtime_enabled_ids = [],
  pending_restart,
  diff,
  form_action,
  setup,
}: {
  app_name?: string
  plugins: Plugin[]
  persisted_enabled_ids: string[]
  runtime_enabled_ids: string[]
  pending_restart?: boolean
  diff?: Record<string, string[]>
  form_action: string
  setup?: unknown
}) {
  const { i18n, t } = useTranslation()
  const { register, handleSubmit } = useHookForm<PluginForm>({
    defaultValues: { plugins: persisted_enabled_ids.length ? persisted_enabled_ids : runtime_enabled_ids },
  })

  return (
    <SetupPage title={t("setup.plugins.page_title")} appName={app_name} step="plugins">
      <SetupPanel
        title={t("setup.plugins.panel_title")}
        footer={
          <Button type="submit" form="setup-plugins-form">
            {t("setup.plugins.save_button")}
            <RiArrowRightSLine data-icon="inline-end" />
          </Button>
        }>
        {pending_restart ? (
          <InfoAlert title={t("setup.plugins.restart_required_title")}>
            {t("setup.plugins.restart_required_message")} {JSON.stringify(diff)}
          </InfoAlert>
        ) : null}
        <ErrorAlert error={setup && "message" in Object(setup) ? setup : undefined} />
        <form
          id="setup-plugins-form"
          className="grid gap-3 xl:grid-cols-2"
          onSubmit={handleSubmit(data => submitInertia(form_action, data))}>
          {plugins.map(plugin => {
            const displayName = localizedText(plugin.metadata?.display_name, i18n.language) || plugin.id
            const description = localizedText(plugin.metadata?.description, i18n.language)

            return (
              <label key={plugin.id} className="flex items-start gap-3 border border-border/70 bg-card/60 px-4 py-4">
                <input type="checkbox" value={plugin.id} className="mt-1 size-4 shrink-0" {...register("plugins")} />
                <span className="grid min-w-0 flex-1 gap-2">
                  <span className="break-words text-sm font-semibold leading-5">{displayName}</span>
                  {description ? (
                    <span className="whitespace-pre-wrap break-words text-xs leading-5 text-muted-foreground">
                      {description}
                    </span>
                  ) : null}
                </span>
              </label>
            )
          })}
        </form>
      </SetupPanel>
    </SetupPage>
  )
}

function localizedText(value: LocalizedText | undefined, locale: string) {
  if (typeof value === "string") return value
  if (!value) return undefined

  return value[locale] || value[baseLocale(locale)] || value["en-US"] || Object.values(value)[0]
}

function baseLocale(locale: string) {
  return locale.split("-")[0]
}
