import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query"
import { useEffect, useMemo } from "react"
import { Button, InfoAlert, SetupPage, SetupPanel } from "./shared"

const queryClient = new QueryClient()

export default function SetupActivateAdmin(props: ActivateProps) {
  return (
    <QueryClientProvider client={queryClient}>
      <ActivateAdminInner {...props} />
    </QueryClientProvider>
  )
}

type ActivateProps = {
  app_name?: string
  activation_code?: string | null
  command?: string | null
  ready_sources?: Array<Record<string, any>>
  status_path: string
  back_path: string
}

function ActivateAdminInner({
  app_name = "BullX",
  activation_code,
  command,
  ready_sources = [],
  status_path,
  back_path,
}: ActivateProps) {
  const { data } = useQuery({
    queryKey: ["setup-activation-status", status_path],
    queryFn: async () => {
      const response = await fetch(status_path, { credentials: "same-origin" })
      return response.json()
    },
    refetchInterval: 5000,
  })

  useEffect(() => {
    if (data?.activated) {
      window.location.assign(data.redirect_to || "/")
    }
  }, [data])

  const sourceSummary = useMemo(() => JSON.stringify(ready_sources, null, 2), [ready_sources])

  return (
    <SetupPage title="Activate Admin" appName={app_name} step="activate_admin">
      <SetupPanel
        title="Activate first admin"
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => window.location.assign(back_path)}>
              Back
            </Button>
            <Button
              type="button"
              onClick={() => copy(command || activation_code || "")}
              disabled={!command && !activation_code}>
              Copy command
            </Button>
          </>
        }>
        {activation_code ? (
          <div className="grid gap-4">
            <div className="border border-border/70 bg-card/60 p-4">
              <p className="text-xs font-semibold uppercase text-muted-foreground">Command</p>
              <pre className="mt-2 overflow-auto font-mono text-lg">{command}</pre>
            </div>
            <div className="border border-border/70 bg-card/60 p-4">
              <p className="text-xs font-semibold uppercase text-muted-foreground">Activation code</p>
              <pre className="mt-2 overflow-auto font-mono text-lg">{activation_code}</pre>
            </div>
          </div>
        ) : (
          <InfoAlert title="Activation code unavailable">
            Reenter the bootstrap code to display the plaintext activation command.
          </InfoAlert>
        )}
        <InfoAlert title={data?.handoff === "pending" ? "Admin handoff pending" : "Activation status"}>
          {JSON.stringify(data || { activated: false })}
        </InfoAlert>
        <InfoAlert title="Configured source">{sourceSummary}</InfoAlert>
      </SetupPanel>
    </SetupPage>
  )
}

function copy(value: string) {
  if (value && navigator.clipboard) {
    void navigator.clipboard.writeText(value)
  }
}
