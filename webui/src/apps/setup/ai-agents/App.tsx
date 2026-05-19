import { useForm as useHookForm } from "react-hook-form"
import {
  Button,
  ErrorAlert,
  FieldGrid,
  InfoAlert,
  SetupPage,
  SetupPanel,
  submitInertia,
  TextAreaField,
  TextField,
} from "../shared"

type AgentForm = {
  agent: {
    agent_principal_id?: string
    uid: string
    display_name: string
    bio?: string
    main_model: string
    mission: string
    soul?: string
    instructions?: string
  }
}

export default function SetupAIAgentsApp({
  app_name = "BullX",
  selected_agent,
  acl_preview = [],
  llm_providers = [],
  form_action,
  error,
}: {
  app_name?: string
  selected_agent?: Record<string, any>
  acl_preview: Array<Record<string, any>>
  llm_providers: Array<Record<string, any>>
  form_action: string
  error?: unknown
}) {
  const mainModel = selected_agent?.profile?.ai_agent?.main_model || defaultModel(llm_providers)
  const { register, handleSubmit } = useHookForm<AgentForm>({
    defaultValues: {
      agent: {
        agent_principal_id: selected_agent?.principal_id || "",
        uid: selected_agent?.uid || "",
        display_name: selected_agent?.display_name || "BullX Agent",
        bio: selected_agent?.bio || "",
        main_model: mainModel,
        mission:
          selected_agent?.profile?.ai_agent?.mission || "Help this BullX Installation handle addressed messages.",
        soul: selected_agent?.profile?.ai_agent?.soul || "",
        instructions: selected_agent?.profile?.ai_agent?.instructions || "",
      },
    },
  })

  return (
    <SetupPage title="Setup AIAgent" appName={app_name} step="ai_agents">
      <SetupPanel
        title="Initial AIAgent"
        footer={
          <Button type="submit" form="setup-agent-form">
            Save AIAgent
          </Button>
        }>
        <ErrorAlert error={error} />
        {acl_preview.length ? <InfoAlert title="ACL preview">{JSON.stringify(acl_preview)}</InfoAlert> : null}
        <form
          id="setup-agent-form"
          className="flex flex-col gap-5"
          onSubmit={handleSubmit(data => submitInertia(form_action, data))}>
          <input type="hidden" {...register("agent.agent_principal_id")} />
          <FieldGrid>
            <TextField label="UID" {...register("agent.uid")} />
            <TextField label="Display name" {...register("agent.display_name")} />
            <TextField label="Main model" {...register("agent.main_model")} />
            <TextField label="Bio" {...register("agent.bio")} />
          </FieldGrid>
          <TextAreaField label="Mission" rows={4} {...register("agent.mission")} />
          <TextAreaField label="Soul" rows={4} {...register("agent.soul")} />
          <TextAreaField label="Instructions" rows={6} {...register("agent.instructions")} />
        </form>
      </SetupPanel>
    </SetupPage>
  )
}

function defaultModel(providers: Array<Record<string, any>>) {
  const providerId = providers[0]?.provider_id || "openai_proxy"
  return `${providerId}:gpt-4.1-mini`
}
