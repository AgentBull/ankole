import { RiArrowRightSLine } from "@remixicon/react"
import { useForm as useHookForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Button, ErrorAlert, FieldGrid, InfoAlert, SetupPage, SetupPanel, submitInertia, TextField } from "../shared"

type GateForm = {
  setup: {
    bootstrap_code: string
    locale: string
  }
}

function localeAutonym(locale: string): string {
  try {
    return new Intl.DisplayNames([locale], { type: "language" }).of(locale) ?? locale
  } catch {
    return locale
  }
}

export default function SetupSessionNew({
  app_name = "BullX",
  form_action,
  current_locale,
  available_locales = [],
  error,
}: {
  app_name?: string
  form_action: string
  current_locale: string
  available_locales: string[]
  error?: string
}) {
  const { t, i18n } = useTranslation()
  const { register, handleSubmit } = useHookForm<GateForm>({
    defaultValues: { setup: { bootstrap_code: "", locale: current_locale } },
  })

  return (
    <SetupPage title={t("setup.session.page_title")} appName={app_name}>
      <SetupPanel
        title={t("setup.session.panel_title")}
        footer={
          <Button type="submit" form="setup-gate-form">
            {t("setup.continue")}
            <RiArrowRightSLine data-icon="inline-end" />
          </Button>
        }>
        <InfoAlert title={t("setup.session.log_hint_title")}>{t("setup.session.log_hint_body")}</InfoAlert>
        <ErrorAlert error={error} />
        <form
          id="setup-gate-form"
          className="flex flex-col gap-5"
          onSubmit={handleSubmit(data => submitInertia(form_action, data))}>
          <FieldGrid>
            <TextField
              label={t("setup.session.bootstrap_code_label")}
              autoComplete="one-time-code"
              {...register("setup.bootstrap_code")}
            />
            <label className="flex flex-col gap-2 text-sm">
              <span className="font-semibold uppercase">{t("setup.session.language_label")}</span>
              <select
                className="h-10 border border-input bg-field px-3"
                {...register("setup.locale", {
                  onChange: event => i18n.changeLanguage(event.target.value),
                })}>
                {available_locales.map(locale => (
                  <option key={locale} value={locale}>
                    {localeAutonym(locale)}
                  </option>
                ))}
              </select>
            </label>
          </FieldGrid>
        </form>
      </SetupPanel>
    </SetupPage>
  )
}
