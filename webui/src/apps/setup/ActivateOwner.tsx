import { RiArrowLeftLine } from "@remixicon/react"
import React from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardFooter, CardHeader, CardTitle } from "@/uikit/components/card"
import SetupLayout from "./Layout"

const POLL_INTERVAL_MS = 5000

interface SetupActivateOwnerProps {
  app_name: string
  command: string
  back_path: string
  status_path: string
}

interface ActivationStatus {
  activated: boolean
  redirect_to?: string
}

export default function SetupActivateOwner({ app_name, command, back_path, status_path }: SetupActivateOwnerProps) {
  const { t } = useTranslation()

  React.useEffect(() => {
    if (!status_path) return undefined

    let cancelled = false

    const tick = async () => {
      try {
        const response = await fetch(status_path, {
          credentials: "same-origin",
          headers: { accept: "application/json" },
        })
        if (cancelled) return
        const data = (await response.json()) as ActivationStatus
        if (data?.activated) window.location.assign(data.redirect_to || "/")
      } catch {
        // swallow transient network errors and try again next tick
      }
    }

    const interval = setInterval(tick, POLL_INTERVAL_MS)
    return () => {
      cancelled = true
      clearInterval(interval)
    }
  }, [status_path])

  return (
    <SetupLayout title={t("web.setup.activate_owner.title")} appName={app_name}>
      <section className="grid flex-1 place-items-center py-8 sm:py-10">
        <Card size="sm" className="w-full max-w-3xl gap-0 bg-card py-0">
          <CardHeader className="border-b border-border px-5 py-4 sm:px-6">
            <div className="min-w-0">
              <p className="text-xs font-medium text-primary">{t("web.setup.activate_owner.step")}</p>
              <CardTitle className="mt-1 text-xl font-semibold">{t("web.setup.activate_owner.heading")}</CardTitle>
            </div>
          </CardHeader>

          <CardContent className="grid gap-5 px-5 py-5 text-sm leading-6 sm:px-6">
            <p>{t("web.setup.activate_owner.saved")}</p>

            <div>
              <p className="font-semibold">{t("web.setup.activate_owner.next_step_label")}</p>
              <p className="mt-2">{t("web.setup.activate_owner.instruction")}</p>
            </div>

            <pre className="border border-border bg-background-secondary px-4 py-3 font-mono text-sm">{command}</pre>

            <p className="text-muted-foreground">{t("web.setup.activate_owner.code_explanation")}</p>

            <p className="text-muted-foreground">{t("web.setup.activate_owner.completion")}</p>
          </CardContent>

          <CardFooter className="justify-start border-t border-border px-5 py-4 sm:px-6">
            <Button type="button" variant="ghost" onClick={() => window.location.assign(back_path)}>
              <RiArrowLeftLine data-icon="inline-start" />
              <span>{t("web.setup.activate_owner.actions.back_to_gateway")}</span>
            </Button>
          </CardFooter>
        </Card>
      </section>
    </SetupLayout>
  )
}
