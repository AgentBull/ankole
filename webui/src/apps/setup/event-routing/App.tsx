import { useForm as useHookForm } from "react-hook-form"
import { Button, ErrorAlert, InfoAlert, SetupPage, SetupPanel, submitInertia } from "../shared"

export default function SetupEventRoutingApp({
  app_name = "BullX",
  routing,
  form_action,
  error,
}: {
  app_name?: string
  routing?: Record<string, any>
  form_action: string
  error?: unknown
}) {
  const { handleSubmit } = useHookForm()

  return (
    <SetupPage title="Setup Event Routing" appName={app_name} step="event_routing">
      <SetupPanel
        title="Event Routing Rule"
        footer={
          <Button type="submit" form="setup-routing-form">
            Save route
          </Button>
        }>
        <ErrorAlert error={error} />
        <InfoAlert title={routing?.["complete?"] ? "Route is live" : "Route needs save"}>
          {JSON.stringify(routing || {})}
        </InfoAlert>
        <form id="setup-routing-form" onSubmit={handleSubmit(() => submitInertia(form_action, {}))} />
      </SetupPanel>
    </SetupPage>
  )
}
