import { Head, useForm, usePage } from "@inertiajs/react"
import { RiArrowRightLine } from "@remixicon/react"
import type React from "react"
import { useTranslation } from "react-i18next"
import logoDark from "@/assets/logo-dark.svg"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/uikit/components/card"
import { InputOTP, InputOTPGroup, InputOTPSeparator, InputOTPSlot } from "@/uikit/components/input-otp"

interface SessionsNewProps {
  form_action: string
  login_providers?: LoginProvider[]
}

interface LoginProvider {
  id: string
  provider: string
  channel_id: string
  label: string
  href: string
}

interface FlashProps {
  [key: string]: unknown
  flash?: { error?: string }
}

function normalizeAuthCode(value: string): string {
  return value
    .replace(/[^a-zA-Z0-9]/g, "")
    .toUpperCase()
    .slice(0, 8)
}

export default function SessionsNew({ form_action, login_providers = [] }: SessionsNewProps) {
  const { t } = useTranslation()
  const { props } = usePage<FlashProps>()
  const flashError = props?.flash?.error
  const { data, setData, post, processing } = useForm({ auth_code: "" })

  const handleCodeChange = (value: string) => {
    setData("auth_code", normalizeAuthCode(value))
  }

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    post(form_action)
  }

  return (
    <main className="min-h-screen bg-background px-4 py-10 text-foreground sm:px-6 lg:px-8">
      <Head title={t("web.sessions.new.title")} />

      <div className="mx-auto flex min-h-[calc(100vh-5rem)] w-full max-w-5xl items-center">
        <section className="w-full">
          <div className="mb-8 flex items-center gap-3">
            <img src={logoDark} className="size-10" alt="" />
            <div>
              <h1 className="text-xl font-semibold">{t("web.sessions.new.brand")}</h1>
              <p className="text-sm text-muted-foreground">{t("web.sessions.new.heading")}</p>
            </div>
          </div>

          <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_24rem]">
            <Card>
              <CardHeader>
                <CardTitle>{t("web.sessions.new.provider_title")}</CardTitle>
                <CardDescription>{t("web.sessions.new.provider_description")}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                {login_providers.length > 0 ? (
                  login_providers.map(provider => (
                    <Button
                      key={provider.id}
                      nativeButton={false}
                      render={<a href={provider.href} />}
                      className="w-full max-w-none justify-between">
                      <span>{provider.label}</span>
                      <RiArrowRightLine data-icon="inline-end" aria-hidden="true" />
                    </Button>
                  ))
                ) : (
                  <p className="border border-border bg-background-secondary px-4 py-3 text-sm leading-5 text-muted-foreground">
                    {t("web.sessions.new.no_providers")}
                  </p>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>{t("web.sessions.new.auth_code_title")}</CardTitle>
                <CardDescription>{t("web.sessions.new.auth_code_description")}</CardDescription>
              </CardHeader>

              <form onSubmit={handleSubmit} className="space-y-8">
                <CardContent className="space-y-3">
                  <label className="block text-xs text-muted-foreground" htmlFor="auth_code">
                    {t("web.sessions.new.auth_code_label")}
                  </label>
                  <InputOTP
                    id="auth_code"
                    name="auth_code"
                    maxLength={8}
                    autoComplete="off"
                    autoCapitalize="characters"
                    spellCheck={false}
                    inputMode="text"
                    pattern="^[a-zA-Z0-9]+$"
                    value={data.auth_code}
                    onChange={handleCodeChange}
                    pasteTransformer={normalizeAuthCode}
                    required
                    containerClassName="w-full justify-between gap-1 bg-field px-2 py-1 sm:gap-2 sm:px-3"
                    className="h-12 font-mono">
                    <InputOTPGroup className="flex-1 justify-between gap-0 sm:gap-1">
                      <InputOTPSlot className="size-7 sm:size-10" index={0} />
                      <InputOTPSlot className="size-7 sm:size-10" index={1} />
                      <InputOTPSlot className="size-7 sm:size-10" index={2} />
                      <InputOTPSlot className="size-7 sm:size-10" index={3} />
                    </InputOTPGroup>
                    <InputOTPSeparator />
                    <InputOTPGroup className="flex-1 justify-between gap-0 sm:gap-1">
                      <InputOTPSlot className="size-7 sm:size-10" index={4} />
                      <InputOTPSlot className="size-7 sm:size-10" index={5} />
                      <InputOTPSlot className="size-7 sm:size-10" index={6} />
                      <InputOTPSlot className="size-7 sm:size-10" index={7} />
                    </InputOTPGroup>
                  </InputOTP>

                  {flashError ? (
                    <p
                      className="border-l-4 border-destructive bg-background-secondary px-4 py-3 text-sm leading-5 text-destructive"
                      role="alert">
                      {flashError}
                    </p>
                  ) : null}
                </CardContent>

                <CardFooter className="flex justify-end">
                  <Button
                    type="submit"
                    disabled={processing || data.auth_code.length < 8}
                    className="w-full justify-between sm:w-36">
                    <span>{t("web.sessions.new.auth_code_submit")}</span>
                    <RiArrowRightLine data-icon="inline-end" aria-hidden="true" />
                  </Button>
                </CardFooter>
              </form>
            </Card>
          </div>
        </section>
      </div>
    </main>
  )
}
