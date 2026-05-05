import { Head } from "@inertiajs/react"
import { useTranslation } from "react-i18next"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/uikit/components/card"

const sections = ["sessions", "approvals", "observability"] as const

interface CurrentUser {
  id: string
  display_name: string
  email: string | null
}

interface ControlPanelAppProps {
  app_name: string
  current_user: CurrentUser
  swagger_ui_path: string | null
}

export default function ControlPanelApp({ app_name, current_user, swagger_ui_path }: ControlPanelAppProps) {
  const { t } = useTranslation()

  return (
    <main className="min-h-screen bg-background text-foreground">
      <Head title={t("web.control_panel.title")} />

      <div className="mx-auto flex min-h-screen w-full max-w-6xl flex-col px-4 py-6 sm:px-6 lg:px-8">
        <header className="flex items-center justify-between border-b border-border pb-4">
          <div className="flex items-center gap-3">
            <img src="/images/logo.svg" className="size-10" alt="" />
            <div>
              <p className="text-lg font-semibold leading-6">{app_name}</p>
              <p className="text-sm text-muted-foreground">{t("web.control_panel.subtitle")}</p>
            </div>
          </div>

          <div className="text-right">
            <p className="text-sm font-medium">{current_user.display_name}</p>
            <p className="text-xs text-muted-foreground">{current_user.email || current_user.id}</p>
          </div>
        </header>

        <section className="grid flex-1 content-center gap-6 py-8 lg:grid-cols-[1fr_22rem]">
          <div className="space-y-6">
            <div>
              <p className="text-sm font-medium uppercase text-primary">{t("web.control_panel.status")}</p>
              <h1 className="mt-3 max-w-3xl text-4xl font-semibold leading-tight sm:text-5xl">
                {t("web.control_panel.heading")}
              </h1>
            </div>

            <div className="grid gap-3 sm:grid-cols-3">
              {sections.map(section => (
                <Card key={section}>
                  <CardHeader>
                    <CardTitle>{t(`web.control_panel.sections.${section}.title`)}</CardTitle>
                    <CardDescription className="leading-6">
                      {t(`web.control_panel.sections.${section}.description`)}
                    </CardDescription>
                  </CardHeader>
                </Card>
              ))}
            </div>
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-sm uppercase text-muted-foreground">
                {t("web.control_panel.api_title")}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <Button
                className="w-full justify-between"
                nativeButton={false}
                render={<a href="/.well-known/service-desc" />}>
                {t("web.control_panel.openapi_json")}
                <span aria-hidden="true">/.well-known/service-desc</span>
              </Button>
              {swagger_ui_path && (
                <Button
                  variant="outline"
                  className="w-full justify-between"
                  nativeButton={false}
                  render={<a href={swagger_ui_path} />}>
                  {t("web.control_panel.swagger_ui")}
                  <span aria-hidden="true">{swagger_ui_path}</span>
                </Button>
              )}
            </CardContent>
          </Card>
        </section>
      </div>
    </main>
  )
}
