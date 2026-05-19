import { router } from "@inertiajs/react"
import type React from "react"
import { Alert, AlertDescription, AlertTitle } from "@/uikit/components/alert"
import { Button } from "@/uikit/components/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/uikit/components/card"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel } from "@/uikit/components/field"
import { Input } from "@/uikit/components/input"
import { Textarea } from "@/uikit/components/textarea"
import SetupLayout from "./Layout"

export type SetupStep =
  | "plugins"
  | "llm_providers"
  | "channel_sources"
  | "ai_agents"
  | "event_routing"
  | "activate_admin"

const STEPS: Array<{ id: SetupStep; label: string }> = [
  { id: "plugins", label: "Plugins" },
  { id: "llm_providers", label: "LLM" },
  { id: "channel_sources", label: "Sources" },
  { id: "ai_agents", label: "AIAgent" },
  { id: "event_routing", label: "Routing" },
  { id: "activate_admin", label: "Activate" },
]

export function SetupPage({
  title,
  appName,
  step,
  children,
}: {
  title: string
  appName?: string
  step?: SetupStep
  children: React.ReactNode
}) {
  return (
    <SetupLayout title={title} appName={appName}>
      <section className="grid flex-1 grid-cols-1 gap-6 py-8 lg:grid-cols-[220px_minmax(0,1fr)]">
        <nav className="h-fit border border-border/70 bg-background/85 p-3 backdrop-blur">
          <ol className="flex flex-row gap-2 overflow-x-auto lg:flex-col lg:overflow-visible">
            {STEPS.map((item, index) => (
              <li key={item.id} className="min-w-28 lg:min-w-0">
                <div
                  data-active={item.id === step ? true : undefined}
                  className="flex h-10 items-center gap-3 border border-transparent px-3 text-sm text-muted-foreground data-active:border-primary data-active:bg-primary data-active:text-primary-foreground">
                  <span className="font-mono text-xs">{String(index + 1).padStart(2, "0")}</span>
                  <span className="truncate">{item.label}</span>
                </div>
              </li>
            ))}
          </ol>
        </nav>
        <div className="min-w-0">{children}</div>
      </section>
    </SetupLayout>
  )
}

export function SetupPanel({
  title,
  children,
  footer,
}: {
  title: string
  children: React.ReactNode
  footer?: React.ReactNode
}) {
  return (
    <Card className="w-full rounded-none border-border/70 bg-background/90 backdrop-blur">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-6">
        {children}
        {footer ? (
          <div className="flex flex-wrap items-center gap-3 border-t border-border/70 pt-5">{footer}</div>
        ) : null}
      </CardContent>
    </Card>
  )
}

export function ErrorAlert({ error, title = "Could not save" }: { error?: unknown; title?: string }) {
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription>
        <pre className="whitespace-pre-wrap text-xs">
          {typeof error === "string" ? error : JSON.stringify(error, null, 2)}
        </pre>
      </AlertDescription>
    </Alert>
  )
}

export function InfoAlert({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Alert>
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription>{children}</AlertDescription>
    </Alert>
  )
}

export function TextField({
  label,
  description,
  error,
  ...props
}: React.ComponentProps<typeof Input> & {
  label: string
  description?: React.ReactNode
  error?: string
}) {
  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input aria-invalid={error ? true : undefined} {...props} />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
      <FieldError>{error}</FieldError>
    </Field>
  )
}

export function TextAreaField({
  label,
  description,
  error,
  ...props
}: React.ComponentProps<typeof Textarea> & {
  label: string
  description?: string
  error?: string
}) {
  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Textarea aria-invalid={error ? true : undefined} {...props} />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
      <FieldError>{error}</FieldError>
    </Field>
  )
}

export function FieldGrid({ children }: { children: React.ReactNode }) {
  return <FieldGroup className="grid gap-5 md:grid-cols-2">{children}</FieldGroup>
}

export function submitInertia(path: string, data: Record<string, unknown>) {
  router.post(path, data, { preserveScroll: true })
}

export async function postJson(path: string, data: unknown) {
  const response = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": csrfToken(),
    },
    body: JSON.stringify(data),
  })

  const json = await response.json()

  if (json?.redirect_to) {
    window.location.assign(json.redirect_to)
    return json
  }

  if (!response.ok || json?.ok === false) {
    throw json
  }

  return json
}

function csrfToken() {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || ""
}

export { Button }
