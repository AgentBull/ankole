import { RiArrowDownSLine, RiArrowRightSLine, RiArrowUpSLine } from "@remixicon/react"
import type React from "react"
import { useState } from "react"
import { useForm as useHookForm } from "react-hook-form"
import { useTranslation } from "react-i18next"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/uikit/components/collapsible"
import { CreatableCombobox } from "@/uikit/components/creatable-combobox"
import { Field, FieldError, FieldLabel } from "@/uikit/components/field"
import { InputGroup, InputGroupAddon, InputGroupInput } from "@/uikit/components/input-group"
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

const DEFAULT_CONTEXT_WINDOW = 80_000
const MIN_MAX_COMPLETION_TOKENS = 200

type LLMConfig = {
  provider_id: string
  model: string
  reasoning_effort: string
  context_window?: number | null
  max_completion_tokens?: number | null
}

type AgentForm = {
  agent: {
    agent_uid?: string
    uid: string
    display_name: string
    main_llm: LLMConfig
    compression_llm: LLMConfig
    heavy_llm: LLMConfig
    mission: string
    soul?: string
    instructions?: string
  }
}

type LLMProvider = {
  provider_id: string
  req_llm_provider?: string
}

type ModelDescriptor = {
  provider_id: string
  model: string
  label?: string
  context_window?: number | null
  fallback_context_window?: number | null
  max_completion_tokens?: number | null
  reasoning?: { efforts?: string[] }
  source?: string
}

export default function SetupAIAgentsApp({
  app_name = "BullX",
  selected_agent,
  default_soul = "",
  acl_preview = [],
  llm_providers = [],
  provider_models = {},
  reasoning_efforts = ["none", "minimal", "low", "medium", "high", "xhigh"],
  form_action,
  back_path,
  error,
}: {
  app_name?: string
  selected_agent?: Record<string, any>
  default_soul?: string
  acl_preview: Array<Record<string, any>>
  llm_providers: LLMProvider[]
  provider_models?: Record<string, ModelDescriptor[]>
  models_path?: string
  reasoning_efforts?: string[]
  form_action: string
  back_path: string
  error?: unknown
}) {
  const { t } = useTranslation()
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const profile = selected_agent?.profile?.ai_agent || {}
  const mainLLM = defaultLLM(profile.main_llm, "medium", provider_models)
  const { register, handleSubmit, watch, setValue } = useHookForm<AgentForm>({
    defaultValues: {
      agent: {
        agent_uid: selected_agent?.principal_uid || "",
        uid: selected_agent?.uid || "",
        display_name: selected_agent?.display_name || "BullX Agent",
        main_llm: mainLLM,
        compression_llm: defaultLLM(profile.compression_llm, "low", provider_models),
        heavy_llm: defaultLLM(profile.heavy_llm, "high", provider_models),
        mission: profile.mission || "",
        soul: profile.soul || default_soul,
        instructions: profile.instructions || "",
      },
    },
  })
  function updateProvider(path: "main_llm" | "compression_llm" | "heavy_llm", effort: string) {
    setValue(`agent.${path}.model`, "")
    setValue(`agent.${path}.context_window`, null)
    setValue(`agent.${path}.max_completion_tokens`, null)
    setValue(`agent.${path}.reasoning_effort`, effort)
  }

  function updateModel(path: "main_llm" | "compression_llm" | "heavy_llm", providerId: string, modelId: string) {
    const descriptor = (provider_models[providerId] || []).find(model => model.model === modelId)
    setValue(`agent.${path}.model`, modelId)
    setValue(`agent.${path}.context_window`, contextWindowFromDescriptor(descriptor))
    setValue(`agent.${path}.max_completion_tokens`, null)
  }

  return (
    <SetupPage title={t("setup.ai_agents.page_title")} appName={app_name} step="ai_agents">
      <SetupPanel
        title={t("setup.ai_agents.panel_title")}
        footer={
          <>
            <Button type="button" variant="outline" onClick={() => window.location.assign(back_path)}>
              {t("setup.back")}
            </Button>
            <Button type="submit" form="setup-agent-form">
              {t("setup.ai_agents.save_button")}
              <RiArrowRightSLine data-icon="inline-end" />
            </Button>
          </>
        }>
        <ErrorAlert error={error} />
        {acl_preview.length ? (
          <InfoAlert title={t("setup.ai_agents.acl_preview_label")}>{JSON.stringify(acl_preview)}</InfoAlert>
        ) : null}
        <form
          id="setup-agent-form"
          className="flex flex-col gap-5"
          onSubmit={handleSubmit(data => submitInertia(form_action, normalizeSubmit(data)))}>
          <input type="hidden" {...register("agent.agent_uid")} />
          <FieldGrid>
            <Field>
              <FieldLabel>{t("setup.ai_agents.bot_username_label")}</FieldLabel>
              <InputGroup>
                <InputGroupAddon align="inline-start">@</InputGroupAddon>
                <InputGroupInput {...register("agent.uid")} />
              </InputGroup>
              <FieldError />
            </Field>
            <TextField label={t("setup.ai_agents.display_name_label")} {...register("agent.display_name")} />
          </FieldGrid>

          <LLMConfigFields
            title={t("setup.ai_agents.main_llm_label")}
            path="main_llm"
            register={register}
            watch={watch}
            providers={llm_providers}
            providerModels={provider_models}
            reasoningEfforts={reasoning_efforts}
            required
            onProviderChange={() => updateProvider("main_llm", "medium")}
            onModelChange={(providerId, modelId) => updateModel("main_llm", providerId, modelId)}
          />

          <TextAreaField
            label={t("setup.ai_agents.mission_label")}
            rows={4}
            required
            placeholder={t("setup.ai_agents.mission_placeholder")}
            {...register("agent.mission")}
          />
          <Collapsible open={advancedOpen} onOpenChange={setAdvancedOpen}>
            <CollapsibleTrigger
              render={
                <Button type="button" variant="outline" className="w-fit">
                  {t("setup.ai_agents.advanced_settings_label")}
                  {advancedOpen ? (
                    <RiArrowUpSLine data-icon="inline-end" />
                  ) : (
                    <RiArrowDownSLine data-icon="inline-end" />
                  )}
                </Button>
              }
            />
            <CollapsibleContent className="mt-5 flex flex-col gap-5 border-t border-border/70 pt-5">
              <LLMConfigFields
                title={t("setup.ai_agents.compression_llm_label")}
                path="compression_llm"
                register={register}
                watch={watch}
                providers={llm_providers}
                providerModels={provider_models}
                reasoningEfforts={reasoning_efforts}
                required={false}
                onProviderChange={() => updateProvider("compression_llm", "low")}
                onModelChange={(providerId, modelId) => updateModel("compression_llm", providerId, modelId)}
              />
              <LLMConfigFields
                title={t("setup.ai_agents.heavy_llm_label")}
                path="heavy_llm"
                register={register}
                watch={watch}
                providers={llm_providers}
                providerModels={provider_models}
                reasoningEfforts={reasoning_efforts}
                required={false}
                onProviderChange={() => updateProvider("heavy_llm", "high")}
                onModelChange={(providerId, modelId) => updateModel("heavy_llm", providerId, modelId)}
              />
              <TextAreaField label={t("setup.ai_agents.soul_label")} rows={16} {...register("agent.soul")} />
              <TextAreaField
                label={t("setup.ai_agents.constraint_rules_label")}
                rows={6}
                {...register("agent.instructions")}
              />
            </CollapsibleContent>
          </Collapsible>
        </form>
      </SetupPanel>
    </SetupPage>
  )
}

function LLMConfigFields({
  title,
  path,
  register,
  watch,
  providers,
  providerModels,
  reasoningEfforts,
  required,
  onProviderChange,
  onModelChange,
}: {
  title: string
  path: "main_llm" | "compression_llm" | "heavy_llm"
  register: ReturnType<typeof useHookForm<AgentForm>>["register"]
  watch: ReturnType<typeof useHookForm<AgentForm>>["watch"]
  providers: LLMProvider[]
  providerModels: Record<string, ModelDescriptor[]>
  reasoningEfforts: string[]
  required: boolean
  onProviderChange: (providerId: string) => void
  onModelChange: (providerId: string, modelId: string) => void
}) {
  const { t } = useTranslation()
  const providerId = watch(`agent.${path}.provider_id`)
  const modelId = watch(`agent.${path}.model`)
  const models = providerModels[providerId] || []

  return (
    <section className="flex flex-col gap-4 border border-border/70 bg-card/30 p-4">
      <p className="text-xs font-semibold uppercase text-muted-foreground">{title}</p>
      <FieldGrid>
        <Field>
          <FieldLabel>{t("setup.ai_agents.llm_provider_label")}</FieldLabel>
          <select
            className="h-10 border border-transparent border-b-input bg-field px-3"
            required={required}
            {...register(`agent.${path}.provider_id`, {
              onChange: event => onProviderChange(event.target.value),
            })}>
            <option value="" disabled>
              {t("setup.ai_agents.llm_provider_placeholder")}
            </option>
            {providers.map(provider => (
              <option key={provider.provider_id} value={provider.provider_id}>
                {provider.provider_id}
              </option>
            ))}
          </select>
          <FieldError />
        </Field>
        <Field>
          <FieldLabel>{t("setup.ai_agents.llm_model_label")}</FieldLabel>
          <CreatableCombobox
            value={modelId}
            options={models.map(model => ({
              value: model.model,
              label: model.label || model.model,
              description: model.source || undefined,
            }))}
            placeholder={t("setup.ai_agents.llm_model_placeholder")}
            emptyLabel={t("setup.ai_agents.llm_model_empty")}
            createLabel={value => t("setup.ai_agents.llm_model_create", { values: { value } })}
            onValueChange={value => onModelChange(providerId, value)}
            disabled={!providerId}
            required={required || providerId !== ""}
          />
          <FieldError />
        </Field>
        <ReasoningEffortField
          label={t("setup.ai_agents.reasoning_effort_label")}
          efforts={reasoningEfforts}
          {...register(`agent.${path}.reasoning_effort`)}
        />
        <TextField
          label={t("setup.ai_agents.context_window_label")}
          type="number"
          min={1}
          placeholder={String(DEFAULT_CONTEXT_WINDOW)}
          description={t("setup.ai_agents.context_window_description")}
          {...register(`agent.${path}.context_window`, { valueAsNumber: true })}
        />
        <TextField
          label={t("setup.ai_agents.max_completion_tokens_label")}
          type="number"
          min={MIN_MAX_COMPLETION_TOKENS}
          description={t("setup.ai_agents.max_completion_tokens_description")}
          {...register(`agent.${path}.max_completion_tokens`, { valueAsNumber: true })}
        />
      </FieldGrid>
    </section>
  )
}

function ReasoningEffortField({
  label,
  efforts,
  ...props
}: React.ComponentProps<"select"> & {
  label: string
  efforts: string[]
}) {
  const { t } = useTranslation()

  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <select className="h-10 border border-transparent border-b-input bg-field px-3" {...props}>
        {efforts.map(effort => (
          <option key={effort} value={effort}>
            {t(`setup.ai_agents.reasoning_efforts.${effort}`, { defaultValue: effort })}
          </option>
        ))}
      </select>
      <FieldError />
    </Field>
  )
}

function defaultLLM(
  config: LLMConfig | undefined,
  effort: string,
  providerModels: Record<string, ModelDescriptor[]>,
): LLMConfig {
  if (config?.provider_id && config?.model) {
    const descriptor = descriptorFor(providerModels, config.provider_id, config.model)

    return {
      provider_id: config.provider_id,
      model: config.model,
      reasoning_effort: config.reasoning_effort || effort,
      context_window: contextWindowForConfig(config, descriptor),
      max_completion_tokens: config.max_completion_tokens || null,
    }
  }

  return emptyLLM(effort)
}

function emptyLLM(effort: string): LLMConfig {
  return {
    provider_id: "",
    model: "",
    reasoning_effort: effort,
    context_window: null,
    max_completion_tokens: null,
  }
}

function contextWindowFromDescriptor(descriptor: ModelDescriptor | undefined) {
  const tokens = descriptor?.context_window
  return positiveInteger(tokens) ? tokens : null
}

function contextWindowForConfig(config: LLMConfig, descriptor: ModelDescriptor | undefined) {
  const tokens = config.context_window

  if (positiveInteger(tokens) && tokens !== DEFAULT_CONTEXT_WINDOW) {
    return tokens
  }

  return contextWindowFromDescriptor(descriptor)
}

function descriptorFor(providerModels: Record<string, ModelDescriptor[]>, providerId: string, modelId: string) {
  return (providerModels[providerId] || []).find(model => model.model === modelId)
}

function positiveInteger(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) > 0
}

function normalizeSubmit(data: AgentForm) {
  const agent = { ...data.agent }

  agent.main_llm = normalizeLLM(agent.main_llm)
  agent.compression_llm = normalizeLLM(agent.compression_llm)
  agent.heavy_llm = normalizeLLM(agent.heavy_llm)

  if (blankLLM(agent.compression_llm)) delete (agent as Partial<AgentForm["agent"]>).compression_llm
  if (blankLLM(agent.heavy_llm)) delete (agent as Partial<AgentForm["agent"]>).heavy_llm

  return { agent }
}

function normalizeLLM(config: LLMConfig) {
  const normalized: LLMConfig = {
    ...config,
    max_completion_tokens: minimumInteger(config.max_completion_tokens, MIN_MAX_COMPLETION_TOKENS)
      ? config.max_completion_tokens
      : null,
  }

  if (positiveInteger(config.context_window)) {
    normalized.context_window = config.context_window
  } else {
    delete normalized.context_window
  }

  if (!minimumInteger(normalized.max_completion_tokens, MIN_MAX_COMPLETION_TOKENS)) {
    delete normalized.max_completion_tokens
  }

  return normalized
}

function blankLLM(config: LLMConfig | undefined) {
  return !config?.provider_id && !config?.model
}

function minimumInteger(value: unknown, min: number): value is number {
  return Number.isInteger(value) && Number(value) >= min
}
