defmodule Ankole.AppConfigure.Declarations do
  alias Ankole.AIGateway.CompactionPolicy
  @moduledoc false

  alias Ankole.AIAgent.Library.AgentPlugins.Config, as: AgentPluginConfig
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Sessions.AgentConfig
  alias Ankole.AgentWorkers.Settings, as: AgentWorkerSettings
  alias Ankole.Sessions.BackgroundAgentJobCap
  alias Ankole.Sessions.DeadLetterNoticeConfig
  alias Ankole.AgentWorkers.WorkerAuthKey
  alias Ankole.AgentWorkers.WorkerWebFetchConfig
  alias Ankole.Workflow.WorkerConfig, as: WorkflowWorkerConfig

  @spec core_definitions() :: [Definition.t()]
  def core_definitions do
    [
      Ankole.Tenants.privileged_definition(),
      Ankole.SystemConfig.timezone_definition(),
      Ankole.Setup.Config.completed_definition(),
      Ankole.Setup.Config.bootstrap_activation_code_definition(),
      Ankole.Plugins.Config.enabled_ids_definition(),
      CompactionPolicy.config_definition(),
      Ankole.Security.SSRFFilter.definition(),
      LocalPassword.RetryGuard.concurrency_definition(),
      WorkerAuthKey.definition(),
      WorkerWebFetchConfig.definition(),
      BackgroundAgentJobCap.definition(),
      Ankole.AgentWorkers.SlotLock.automation_capacity_definition(),
      DeadLetterNoticeConfig.definition()
    ] ++
      WorkflowWorkerConfig.definitions() ++
      AgentWorkerSettings.definitions() ++
      Ankole.Brain.Config.definitions() ++
      Ankole.Pod.Config.definitions() ++
      Ankole.I18n.Config.definitions() ++
      Ankole.Observability.definitions() ++
      AgentPluginConfig.definitions() ++
      IdentityProviderConfig.definitions() ++
      AgentConfig.definitions()
  end

  @spec core_patterns() :: [PatternDefinition.t()]
  def core_patterns do
    [LocalPassword.app_config_pattern()]
  end
end
