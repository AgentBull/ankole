defmodule Ankole.AppConfigure.Declarations do
  @moduledoc false

  alias Ankole.AIAgent.Library.AgentPlugins.Config, as: AgentPluginConfig
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig
  alias Ankole.SignalsGateway.ActorRuntime.DeadLetterNoticeConfig
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfig

  @spec core_definitions() :: [Definition.t()]
  def core_definitions do
    [
      Ankole.SystemConfig.timezone_definition(),
      Ankole.Setup.Config.completed_definition(),
      Ankole.Setup.Config.bootstrap_activation_code_definition(),
      Ankole.Plugins.Config.enabled_ids_definition(),
      Ankole.AIGateway.Compaction.config_definition(),
      Ankole.Security.SSRFFilter.definition(),
      WorkerAuthKey.definition(),
      WorkerWebFetchConfig.definition(),
      BackgroundAgentJobWorkerConfig.definition(),
      BackgroundAgentJobWorkerConfig.agent_cap_definition(),
      DeadLetterNoticeConfig.definition()
    ] ++
      Ankole.Brain.Config.definitions() ++
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
