import { Card, CardContent, CardHeader, CardTitle } from "@/uikit/components/card"
import SetupLayout from "./Layout"

interface SetupAppProps {
  app_name?: string
}

export default function SetupApp({ app_name = "BullX" }: SetupAppProps) {
  return (
    <SetupLayout title="Setup" appName={app_name}>
      <section className="grid flex-1 place-items-center py-12">
        <Card className="w-full max-w-xl">
          <CardHeader>
            <CardTitle>Placeholder</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-sm leading-6 text-muted-foreground">No setup flow is defined on this branch.</p>
          </CardContent>
        </Card>
      </section>
    </SetupLayout>
  )
}
