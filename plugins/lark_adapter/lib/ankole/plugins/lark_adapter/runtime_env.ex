defmodule Ankole.Plugins.LarkAdapter.RuntimeEnv do
  @moduledoc """
  Projects one Lark signal binding into the official lark-cli environment.

  Agent Computer is a trusted first-party worker. The existing FeishuOpenAPI
  token manager uses the binding's app credentials and supplies the app ID plus
  cached tenant token once when WorkerEnv resolves for the Turn, but only while
  the binding's Agent has the `lark` Agent Plugin effectively enabled. Strict
  bot mode rejects user identity before any request is sent.
  """

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.SignalsGateway.Binding
  alias FeishuOpenAPI.TokenManager

  @spec resolve_worker_env(Binding.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def resolve_worker_env(%Binding{} = binding) do
    with {:ok, true} <- AgentPlugins.effective_enabled?(binding.agent_uid, "lark"),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         {:ok, token} <- TokenManager.get_tenant_token(Config.client(config)) do
      {:ok,
       %{
         "LARKSUITE_CLI_APP_ID" => Map.fetch!(config, "appID"),
         "LARKSUITE_CLI_TENANT_ACCESS_TOKEN" => token,
         "LARKSUITE_CLI_BRAND" => Map.fetch!(config, "domain"),
         "LARKSUITE_CLI_DEFAULT_AS" => "bot",
         "LARKSUITE_CLI_STRICT_MODE" => "bot"
       }}
    else
      {:ok, false} -> {:ok, %{}}
      {:error, _reason} = error -> error
    end
  end

  def resolve_worker_env(_binding), do: {:error, :invalid_lark_binding}
end
