import { useForm as useHookForm } from "react-hook-form"
import { Button, ErrorAlert, FieldGrid, SetupPage, SetupPanel, submitInertia, TextField } from "../shared"

type GateForm = {
  setup: {
    bootstrap_code: string
    locale: string
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
  const { register, handleSubmit } = useHookForm<GateForm>({
    defaultValues: { setup: { bootstrap_code: "", locale: current_locale } },
  })

  return (
    <SetupPage title="Setup" appName={app_name}>
      <SetupPanel
        title="Bootstrap gate"
        footer={
          <Button type="submit" form="setup-gate-form">
            Continue
          </Button>
        }>
        <ErrorAlert error={error} />
        <form
          id="setup-gate-form"
          className="flex flex-col gap-5"
          onSubmit={handleSubmit(data => submitInertia(form_action, data))}>
          <FieldGrid>
            <TextField label="Bootstrap code" autoComplete="one-time-code" {...register("setup.bootstrap_code")} />
            <label className="flex flex-col gap-2 text-sm">
              <span className="font-semibold uppercase">Language</span>
              <select className="h-10 border border-input bg-field px-3" {...register("setup.locale")}>
                {available_locales.map(locale => (
                  <option key={locale} value={locale}>
                    {locale}
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
