import { Head, router } from "@inertiajs/react"
import { RiArrowRightLine } from "@remixicon/react"
import { useTranslation } from "react-i18next"
import logoDark from "@/assets/logo-dark.svg"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/uikit/components/card"

interface CurrentUser {
  id: string
  display_name: string
  email: string | null
}

interface NoAccessProps {
  app_name: string
  current_user: CurrentUser
}

export default function NoAccess({ app_name, current_user }: NoAccessProps) {
  const { t } = useTranslation()

  return (
    <main className="min-h-screen bg-background px-4 py-10 text-foreground sm:px-6 lg:px-8">
      <Head title={t("web.control_panel.no_access.title")} />

      <div className="mx-auto flex min-h-[calc(100vh-5rem)] w-full max-w-3xl items-center">
        <section className="w-full">
          <div className="mb-8 flex items-center gap-3">
            <img src={logoDark} className="size-10" alt="" />
            <div>
              <p className="text-lg font-semibold leading-6">{app_name}</p>
              <p className="text-sm text-muted-foreground">{t("web.control_panel.no_access.subtitle")}</p>
            </div>
          </div>

          <Card>
            <CardHeader>
              <CardTitle>{t("web.control_panel.no_access.heading")}</CardTitle>
            </CardHeader>
            <CardContent className="space-y-6">
              <p className="max-w-2xl text-sm leading-6 text-muted-foreground">
                {t("web.control_panel.no_access.description")}
              </p>
              <div className="border border-border bg-background-secondary p-4 text-sm">
                <p className="font-medium">{current_user.display_name}</p>
                <p className="mt-1 text-muted-foreground">{current_user.email || current_user.id}</p>
              </div>
              <Button type="button" onClick={() => router.delete("/sessions")} className="justify-between">
                <span>{t("web.control_panel.no_access.sign_out")}</span>
                <RiArrowRightLine data-icon="inline-end" aria-hidden="true" />
              </Button>
            </CardContent>
          </Card>
        </section>
      </div>
    </main>
  )
}
