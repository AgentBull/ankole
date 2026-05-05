import { useForm, usePage } from "@inertiajs/react"
import { RiArrowRightLine } from "@remixicon/react"
import type React from "react"
import { useTranslation } from "react-i18next"
import i18n from "@/i18n/i18n"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/uikit/components/card"
import { InputOTP, InputOTPGroup, InputOTPSeparator, InputOTPSlot } from "@/uikit/components/input-otp"
import { Select, SelectContent, SelectItem, SelectTrigger } from "@/uikit/components/select"
import SetupLayout from "../Layout"

const LOCALE_LABELS: Record<string, string> = {
  "en-US": "English",
  "zh-Hans-CN": "简体中文",
}

interface SetupSessionNewProps {
  form_action: string
  current_locale: string
  available_locales: string[]
}

interface FlashProps {
  [key: string]: unknown
  flash?: { error?: string }
}

function localeLabel(code: string): string {
  return LOCALE_LABELS[code] || code
}

function normalizeActivationCode(value: string): string {
  return value
    .replace(/[^a-zA-Z0-9]/g, "")
    .toUpperCase()
    .slice(0, 8)
}

export default function SetupSessionNew({ form_action, current_locale, available_locales }: SetupSessionNewProps) {
  const { t } = useTranslation()
  const { props } = usePage<FlashProps>()
  const flashError = props?.flash?.error

  const { data, setData, post, processing } = useForm({
    bootstrap_code: "",
    locale: current_locale,
  })

  const handleLocaleChange = (value: string | null) => {
    if (!value) return
    setData("locale", value)
    i18n.changeLanguage(value)
  }

  const handleCodeChange = (value: string) => {
    setData("bootstrap_code", normalizeActivationCode(value))
  }

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    post(form_action)
  }

  return (
    <SetupLayout
      title={t("web.setup.sessions.new.title")}
      headerActions={
        <Select value={data.locale} onValueChange={handleLocaleChange}>
          <SelectTrigger size="sm" aria-label={t("web.setup.sessions.new.locale_label")} className="bg-field">
            <span data-slot="select-value" className="flex flex-1 items-center gap-2 text-left">
              {localeLabel(data.locale)}
            </span>
          </SelectTrigger>
          <SelectContent align="end">
            {available_locales.map(code => (
              <SelectItem key={code} value={code}>
                {localeLabel(code)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      }>
      <section className="grid flex-1 place-items-center py-10 lg:py-0">
        <div className="w-full max-w-md">
          <Card className="bg-card">
            <CardHeader>
              <CardTitle>{t("web.setup.sessions.new.heading")}</CardTitle>
              <CardDescription>{t("web.setup.sessions.new.description")}</CardDescription>
            </CardHeader>

            <form onSubmit={handleSubmit} className="space-y-12">
              <CardContent className="space-y-2">
                <InputOTP
                  id="bootstrap_code"
                  name="bootstrap_code"
                  maxLength={8}
                  autoComplete="off"
                  autoCapitalize="characters"
                  spellCheck={false}
                  inputMode="text"
                  pattern="^[a-zA-Z0-9]+$"
                  value={data.bootstrap_code}
                  onChange={handleCodeChange}
                  pasteTransformer={normalizeActivationCode}
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
                <Button type="submit" disabled={processing} className="w-full justify-between sm:w-32">
                  <span>{t("web.setup.sessions.new.submit")}</span>
                  <RiArrowRightLine data-icon="inline-end" aria-hidden="true" />
                </Button>
              </CardFooter>
            </form>
          </Card>
        </div>
      </section>
    </SetupLayout>
  )
}
