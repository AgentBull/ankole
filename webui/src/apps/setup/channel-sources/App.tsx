import { useState } from "react"
import { useForm as useHookForm } from "react-hook-form"
import {
  Button,
  ErrorAlert,
  FieldGrid,
  InfoAlert,
  postJson,
  SetupPage,
  SetupPanel,
  submitInertia,
  TextField,
} from "../shared"

type SourceForm = {
  adapter_id: string
  source: {
    id: string
    domain: string
    connected_realm_ref?: string
    web_login_disabled: boolean
    oidc: {
      enabled: boolean
      redirect_uri?: string
    }
    im_listen_mode: string
    start_transport: boolean
  }
  credentials: {
    credential_id: string
    app_id: string
    app_secret: string
    verification_token?: string
    encrypt_key?: string
  }
}

export default function SetupChannelSourcesApp({
  app_name = "BullX",
  adapters = [],
  ready_sources = [],
  form_action,
  check_path,
  generated_secret_path,
  error,
}: {
  app_name?: string
  adapters: Array<Record<string, any>>
  ready_sources: Array<Record<string, any>>
  form_action: string
  check_path: string
  generated_secret_path: string
  error?: unknown
}) {
  const adapter = adapters[0]
  const source = adapter?.projection?.sources?.[0] || adapter?.form_schema?.default_source || {}
  const [operationResult, setOperationResult] = useState<unknown>()
  const { register, handleSubmit, getValues, setValue } = useHookForm<SourceForm>({
    defaultValues: {
      adapter_id: adapter?.id || "feishu",
      source: {
        id: source.id || "main",
        domain: source.domain || "feishu",
        connected_realm_ref: source.connected_realm_ref || "",
        web_login_disabled: source.web_login_disabled ?? false,
        oidc: {
          enabled: source.oidc?.enabled ?? true,
          redirect_uri: source.oidc?.redirect_uri || "",
        },
        im_listen_mode: source.im_listen_mode || "addressed_only",
        start_transport: source.start_transport ?? true,
      },
      credentials: {
        credential_id: source.credential_id || "default",
        app_id: adapter?.projection?.credentials?.default?.app_id || "",
        app_secret: "",
        verification_token: "",
        encrypt_key: "",
      },
    },
  })

  async function checkSource() {
    const result = await postJson(check_path, getValues())
    setOperationResult(result)
  }

  async function generateVerificationToken() {
    const result = await postJson(generated_secret_path, {
      adapter_id: getValues("adapter_id"),
      path: ["credentials", "verification_token"],
    })
    if (result?.value) setValue("credentials.verification_token", result.value)
  }

  return (
    <SetupPage title="Setup Channel Sources" appName={app_name} step="channel_sources">
      <SetupPanel
        title="Channel source"
        footer={
          adapters.length ? (
            <>
              <Button type="button" variant="outline" onClick={generateVerificationToken}>
                Generate token
              </Button>
              <Button type="button" variant="outline" onClick={checkSource}>
                Check
              </Button>
              <Button type="submit" form="setup-source-form">
                Save source
              </Button>
            </>
          ) : null
        }>
        <ErrorAlert error={error} />
        {adapters.length ? null : (
          <InfoAlert title="No setup-capable Channel Adapter">
            Enable a first-party plugin with a setup module, then restart BullX.
          </InfoAlert>
        )}
        {ready_sources.length ? <InfoAlert title="Runtime ready">{JSON.stringify(ready_sources)}</InfoAlert> : null}
        {operationResult ? <InfoAlert title="Operation result">{JSON.stringify(operationResult)}</InfoAlert> : null}
        {adapters.length ? (
          <form
            id="setup-source-form"
            className="flex flex-col gap-5"
            onSubmit={handleSubmit(data => submitInertia(form_action, data as any))}>
            <input type="hidden" {...register("adapter_id")} />
            <FieldGrid>
              <TextField label="Source id" {...register("source.id")} />
              <label className="flex flex-col gap-2 text-sm">
                <span className="font-semibold uppercase">Domain</span>
                <select className="h-10 border border-input bg-field px-3" {...register("source.domain")}>
                  <option value="feishu">feishu</option>
                  <option value="lark">lark</option>
                </select>
              </label>
              <TextField label="Connected Realm ref" {...register("source.connected_realm_ref")} />
              <label className="flex items-center gap-3 text-sm">
                <input type="checkbox" className="size-4" {...register("source.oidc.enabled")} />
                Enable OIDC login
              </label>
              <TextField label="OIDC redirect URI" {...register("source.oidc.redirect_uri")} />
              <label className="flex items-center gap-3 text-sm">
                <input type="checkbox" className="size-4" {...register("source.web_login_disabled")} />
                Disable web login
              </label>
              <label className="flex flex-col gap-2 text-sm">
                <span className="font-semibold uppercase">IM listen mode</span>
                <select className="h-10 border border-input bg-field px-3" {...register("source.im_listen_mode")}>
                  <option value="addressed_only">addressed_only</option>
                  <option value="all_messages">all_messages</option>
                </select>
              </label>
              <TextField label="Credential id" {...register("credentials.credential_id")} />
              <TextField label="App id" {...register("credentials.app_id")} />
              <TextField label="App secret" type="password" {...register("credentials.app_secret")} />
              <TextField label="Verification token" {...register("credentials.verification_token")} />
              <TextField label="Encrypt key" type="password" {...register("credentials.encrypt_key")} />
              <label className="flex items-center gap-3 text-sm">
                <input type="checkbox" className="size-4" {...register("source.start_transport")} />
                Start transport
              </label>
            </FieldGrid>
          </form>
        ) : null}
      </SetupPanel>
    </SetupPage>
  )
}
