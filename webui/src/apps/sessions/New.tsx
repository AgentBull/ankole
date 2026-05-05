import { Head } from "@inertiajs/react"
import { useTranslation } from "react-i18next"
import logoDark from "@/assets/logo-dark.svg"
import { Card, CardContent } from "@/uikit/components/card"

interface SessionsNewProps {
  form_action: string
}

export default function SessionsNew({ form_action }: SessionsNewProps) {
  const { t } = useTranslation()

  return (
    <main className="min-h-screen bg-background px-4 py-10 text-foreground sm:px-6 lg:px-8">
      <Head title={t("web.sessions.new.title")} />

      <div className="mx-auto flex min-h-[calc(100vh-5rem)] w-full max-w-md items-center">
        <section className="w-full">
          <div className="mb-8 flex items-center gap-3">
            <img src={logoDark} className="size-10" alt="" />
            <div>
              <h1 className="text-xl font-semibold">{t("web.sessions.new.brand")}</h1>
            </div>
          </div>

          <Card>
            <CardContent>
              <p className="text-sm leading-6 text-muted-foreground">
                {t("web.sessions.new.placeholder", {
                  values: { form_action },
                })}
              </p>
            </CardContent>
          </Card>
        </section>
      </div>
    </main>
  )
}
