import { Head } from "@inertiajs/react"
import { useTranslation } from "react-i18next"
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/uikit/components/empty"

export default function SetupApp() {
  const { t } = useTranslation()

  return (
    <main className="flex min-h-screen items-center justify-center bg-background text-foreground">
      <Head title={t("web.setup.title")} />
      <Empty>
        <EmptyHeader>
          <EmptyTitle>{t("web.setup.heading")}</EmptyTitle>
          <EmptyDescription>{t("web.setup.description")}</EmptyDescription>
        </EmptyHeader>
      </Empty>
    </main>
  )
}
