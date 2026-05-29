import { useMutation } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Alert, AlertDescription, AlertTitle } from "@/uikit/components/alert"
import { Button } from "@/uikit/components/button"
import { Field, FieldDescription, FieldLabel } from "@/uikit/components/field"
import { Input } from "@/uikit/components/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/uikit/components/select"
import { Spinner } from "@/uikit/components/spinner"
import { Switch } from "@/uikit/components/switch"
import { checkChannelConnectivityMutation } from "../../api/client/@tanstack/react-query.gen"
import type { ChannelAdapter } from "../../api/client/types.gen"
import { errorMessage } from "../../lib/errors"
import {
  asFormSchema,
  buildCallbackUrl,
  callbackEnabled,
  type FormField,
  fieldLabel,
  getPath,
  humanizeOption,
  isSourceIdField,
  type SourceValues,
  schemaFields,
  secretPresent,
  setPath,
  sourceFieldPath,
} from "./fields"

type ChannelFormProps = {
  adapter: ChannelAdapter
  mode: "create" | "edit"
  initialSource: SourceValues
  existingConfig?: SourceValues
  oidcCallbackUrlTemplate?: string
  submitting: boolean
  submitError?: string
  submitLabel: string
  onSubmit: (source: SourceValues) => void
}

export function ChannelForm({
  adapter,
  mode,
  initialSource,
  existingConfig,
  oidcCallbackUrlTemplate,
  submitting,
  submitError,
  submitLabel,
  onSubmit,
}: ChannelFormProps) {
  const { t } = useTranslation()
  const schema = asFormSchema(adapter.form_schema)
  const fields = schemaFields(schema)
  const [source, setSource] = useState<SourceValues>(initialSource)
  const check = useMutation(checkChannelConnectivityMutation())

  function update(path: string[], value: unknown) {
    setSource(current => setPath(current, path, value))
  }

  function renderField(field: FormField) {
    const key = field.path.join(".")
    const path = sourceFieldPath(field)
    const value = getPath(source, path)
    const required = field.required === true

    if (field.kind === "callback_url") {
      if (!callbackEnabled(source, field)) {
        return null
      }
      return (
        <Field key={key} className="md:col-span-2">
          <FieldLabel>Callback URL</FieldLabel>
          <Input readOnly value={buildCallbackUrl(oidcCallbackUrlTemplate, source.id)} className="font-mono text-xs" />
          <FieldDescription>Register this redirect URI with your identity provider.</FieldDescription>
        </Field>
      )
    }

    if (field.kind === "boolean") {
      return (
        <div
          key={key}
          className="flex items-center justify-between gap-3 self-end border border-border bg-card px-4 py-2.5">
          <span className="text-sm">{fieldLabel(field)}</span>
          <Switch checked={Boolean(value)} onCheckedChange={next => update(path, next)} />
        </div>
      )
    }

    if (field.kind === "select") {
      const groupMessageMode = field.path[field.path.length - 1] === "group_message_mode"
      return (
        <Field key={key}>
          <RequiredLabel label={fieldLabel(field)} required={required} />
          <Select value={value == null ? "" : String(value)} onValueChange={next => update(path, next ?? "")}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder="Select…" />
            </SelectTrigger>
            <SelectContent>
              {(field.options ?? []).map(option => (
                <SelectItem key={option} value={option}>
                  {groupMessageMode
                    ? t(`setup.channel_sources.group_message_modes.${option}`, { defaultValue: humanizeOption(option) })
                    : humanizeOption(option)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </Field>
      )
    }

    const idField = isSourceIdField(field)
    const readOnly = mode === "edit" && idField

    const isSecret = field.kind === "secret"
    const secretSaved = secretPresent(existingConfig, field)
    // A required secret on edit can stay blank to keep the stored value.
    const requiredAttr = required && !(isSecret && mode === "edit")

    return (
      <Field key={key}>
        <RequiredLabel label={fieldLabel(field)} required={requiredAttr} />
        <Input
          type={isSecret ? "password" : "text"}
          value={value == null ? "" : String(value)}
          disabled={readOnly}
          required={requiredAttr}
          autoComplete={isSecret ? "new-password" : "off"}
          placeholder={isSecret && secretSaved ? "•••••• (saved)" : undefined}
          onChange={event => update(path, event.target.value)}
        />
        {isSecret && secretSaved ? <FieldDescription>Leave blank to keep the saved secret.</FieldDescription> : null}
      </Field>
    )
  }

  const idField = fields.find(isSourceIdField)
  const credentialFields = fields.filter(field => field.ui?.group === "credentials")
  const restFields = fields.filter(field => !isSourceIdField(field) && field.ui?.group !== "credentials")

  return (
    <form
      className="flex flex-col gap-6"
      onSubmit={event => {
        event.preventDefault()
        onSubmit(source)
      }}>
      {submitError ? (
        <Alert variant="destructive">
          <AlertTitle>Could not save channel</AlertTitle>
          <AlertDescription>{submitError}</AlertDescription>
        </Alert>
      ) : null}

      <div className="flex items-center justify-between gap-4 border border-border bg-card p-4">
        <div className="flex flex-col gap-0.5">
          <span className="text-sm font-medium">Enabled</span>
          <span className="text-xs text-muted-foreground">Disabled channels stay configured but don't connect.</span>
        </div>
        <Switch checked={source.enabled !== false} onCheckedChange={value => update(["enabled"], value)} />
      </div>

      <div className="grid gap-5 md:grid-cols-2">
        {idField ? renderField(idField) : null}
        {credentialFields.length ? (
          <div className="grid gap-5 md:col-span-2 md:grid-cols-2">{credentialFields.map(renderField)}</div>
        ) : null}
        {restFields.map(renderField)}
      </div>

      {check.data ? (
        <Alert>
          <AlertTitle>Connection looks good</AlertTitle>
          <AlertDescription>
            <pre className="overflow-auto text-xs">{JSON.stringify(check.data.result, null, 2)}</pre>
          </AlertDescription>
        </Alert>
      ) : null}
      {check.error ? (
        <Alert variant="destructive">
          <AlertTitle>Connection failed</AlertTitle>
          <AlertDescription>{errorMessage(check.error)}</AlertDescription>
        </Alert>
      ) : null}

      <div className="flex flex-wrap items-center gap-3 border-t border-border pt-5">
        <Button type="submit" disabled={submitting}>
          {submitting ? <Spinner /> : null}
          {submitLabel}
        </Button>
        <Button
          type="button"
          variant="outline"
          disabled={check.isPending}
          onClick={() => check.mutate({ body: { adapter_id: adapter.id, source } })}>
          {check.isPending ? <Spinner /> : null}
          Test connection
        </Button>
        <Button type="button" variant="ghost" render={<Link to="/channels" />}>
          Cancel
        </Button>
      </div>
    </form>
  )
}

function RequiredLabel({ label, required }: { label: string; required: boolean }) {
  return (
    <FieldLabel>
      {label}
      {required ? <span className="text-destructive"> *</span> : null}
    </FieldLabel>
  )
}
