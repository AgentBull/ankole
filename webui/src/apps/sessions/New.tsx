import { RiArrowRightSLine, RiExternalLinkLine } from "@remixicon/react"
import { useForm as useHookForm } from "react-hook-form"
import { Trans } from "react-i18next"
import SetupLayout from "@/apps/setup/Layout"
import { ErrorAlert, submitInertia, TextField } from "@/apps/setup/shared"
import { buttonVariants } from "@/uikit/components/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/uikit/components/card"
import { cn } from "@/uikit/lib/utils"

type LoginProvider = {
  id: string
  provider?: string
  source_id?: string
  label?: string
  href: string
}

type LoginForm = {
  code: string
  return_to: string
}

export default function SessionNew({
  app_name = "BullX",
  form_action,
  return_to = "/",
  providers = [],
  error,
}: {
  app_name?: string
  form_action: string
  return_to?: string
  providers?: LoginProvider[]
  error?: string
}) {
  const { register, handleSubmit } = useHookForm<LoginForm>({
    defaultValues: { code: "", return_to },
  })

  return (
    <SetupLayout title="Sign in" appName={app_name} subtitle="Session">
      <section className="flex flex-1 items-center justify-center py-8">
        <Card className="w-full max-w-md rounded-none border-border/70 bg-background/90 backdrop-blur">
          <CardHeader>
            <CardTitle>Sign in</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-6">
            <ErrorAlert title="Could not sign in" error={error} />
            <form
              id="login-auth-form"
              className="flex flex-col gap-5"
              onSubmit={handleSubmit(data => submitInertia(form_action, data))}>
              <input type="hidden" {...register("return_to")} />
              <TextField
                label="Login code"
                description={<LoginCodeHelp />}
                autoComplete="one-time-code"
                autoCapitalize="characters"
                spellCheck={false}
                className="font-mono uppercase"
                {...register("code")}
              />
            </form>
            <div className="flex flex-col gap-3 border-t border-border/70 pt-5">
              <ButtonFormSubmit />
              {providers.length > 0 ? (
                <div className="flex flex-col gap-3">
                  {providers.map(provider => (
                    <a
                      key={provider.id}
                      className={cn(buttonVariants({ variant: "outline" }), "w-full max-w-none justify-between")}
                      href={provider.href}>
                      Continue with {provider.label || provider.id}
                      <RiExternalLinkLine data-icon="inline-end" />
                    </a>
                  ))}
                </div>
              ) : null}
            </div>
          </CardContent>
        </Card>
      </section>
    </SetupLayout>
  )
}

export function LoginCodeHelp() {
  return <Trans i18nKey="sessions.login_code_help" />
}

function ButtonFormSubmit() {
  return (
    <button type="submit" form="login-auth-form" className={cn(buttonVariants(), "w-full max-w-none justify-between")}>
      Sign in
      <RiArrowRightSLine data-icon="inline-end" />
    </button>
  )
}
