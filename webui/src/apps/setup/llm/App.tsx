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
  TextAreaField,
  TextField,
} from "../shared"

type ProviderDraft = {
  provider_id: string
  req_llm_provider: string
  base_url?: string
  api_key?: string
  provider_options: string
  test_model_id?: string
}

export default function SetupLLMApp({
  app_name = "BullX",
  providers = [],
  req_llm_providers = [],
  form_action,
  check_path,
  error,
}: {
  app_name?: string
  providers: Array<Record<string, any>>
  req_llm_providers: string[]
  form_action: string
  check_path: string
  error?: unknown
}) {
  const first = providers[0]
  const [checkResult, setCheckResult] = useState<unknown>()
  const { register, handleSubmit, getValues } = useHookForm<ProviderDraft>({
    defaultValues: {
      provider_id: first?.provider_id || "openai_proxy",
      req_llm_provider: first?.req_llm_provider || req_llm_providers[0] || "openai",
      base_url: first?.base_url || "",
      api_key: "",
      provider_options: JSON.stringify(first?.provider_options || {}, null, 2),
      test_model_id: "",
    },
  })

  const providerPayload = (draft: ProviderDraft) => ({
    ...draft,
    provider_options: parseJsonObject(draft.provider_options),
  })

  async function checkProvider() {
    const result = await postJson(check_path, { provider: providerPayload(getValues()) })
    setCheckResult(result)
  }

  return (
    <SetupPage title="Setup LLM" appName={app_name} step="llm_providers">
      <SetupPanel
        title="LLM provider"
        footer={
          <>
            <Button type="button" variant="outline" onClick={checkProvider}>
              Check
            </Button>
            <Button type="submit" form="setup-llm-form">
              Save provider
            </Button>
          </>
        }>
        <ErrorAlert error={error} />
        {checkResult ? <InfoAlert title="Check result">{JSON.stringify(checkResult)}</InfoAlert> : null}
        <form
          id="setup-llm-form"
          className="flex flex-col gap-5"
          onSubmit={handleSubmit(draft => submitInertia(form_action, { providers: [providerPayload(draft)] }))}>
          <FieldGrid>
            <TextField label="Provider id" {...register("provider_id")} />
            <label className="flex flex-col gap-2 text-sm">
              <span className="font-semibold uppercase">ReqLLM provider</span>
              <select className="h-10 border border-input bg-field px-3" {...register("req_llm_provider")}>
                {req_llm_providers.map(provider => (
                  <option key={provider} value={provider}>
                    {provider}
                  </option>
                ))}
              </select>
            </label>
            <TextField label="Base URL" {...register("base_url")} />
            <TextField label="API key" type="password" {...register("api_key")} />
            <TextField label="Test model id" {...register("test_model_id")} />
          </FieldGrid>
          <TextAreaField label="Provider options" rows={8} {...register("provider_options")} />
        </form>
      </SetupPanel>
    </SetupPage>
  )
}

function parseJsonObject(value: string) {
  try {
    const parsed = JSON.parse(value || "{}")
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
  } catch {
    return {}
  }
}
