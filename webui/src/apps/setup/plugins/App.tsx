import { useForm as useHookForm } from "react-hook-form"
import { Button, ErrorAlert, InfoAlert, SetupPage, SetupPanel, submitInertia } from "../shared"

type Plugin = {
  id: string
  app: string
  enabled?: boolean
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
  const { register, handleSubmit } = useHookForm<PluginForm>({
    defaultValues: { plugins: persisted_enabled_ids.length ? persisted_enabled_ids : runtime_enabled_ids },
  })

  return (
    <SetupPage title="Setup Plugins" appName={app_name} step="plugins">
      <SetupPanel
        title="Plugins"
        footer={
          <Button type="submit" form="setup-plugins-form">
            Save plugins
          </Button>
        }>
        {pending_restart ? (
          <InfoAlert title="Restart required">
            Persisted plugin ids differ from the runtime registry: {JSON.stringify(diff)}.
          </InfoAlert>
        ) : null}
        <ErrorAlert error={setup && "message" in Object(setup) ? setup : undefined} />
        <form
          id="setup-plugins-form"
          className="grid gap-3 md:grid-cols-2"
          onSubmit={handleSubmit(data => submitInertia(form_action, data))}>
          {plugins.map(plugin => (
            <label key={plugin.id} className="flex min-h-14 items-center gap-3 border border-border/70 bg-card/60 px-4">
              <input type="checkbox" value={plugin.id} className="size-4" {...register("plugins")} />
              <span className="min-w-0">
                <span className="block truncate text-sm font-semibold">{plugin.id}</span>
                <span className="block truncate text-xs text-muted-foreground">{plugin.app}</span>
              </span>
            </label>
          ))}
        </form>
      </SetupPanel>
    </SetupPage>
  )
}
