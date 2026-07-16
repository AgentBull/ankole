defmodule Ankole.Plugins.LarkAdapter.RuntimeEnv do
  @moduledoc """
  Projects one Lark signal binding into the official lark-cli environment.

  Agent Computer is a trusted first-party worker. The existing FeishuOpenAPI
  token manager uses the binding's app credentials and supplies the app ID plus
  cached tenant token once when WorkerEnv resolves for the Turn. Strict bot
  mode rejects user identity before any request is sent.
  Bindings with a custom `baseURL` remain valid for signal delivery but project
  no CLI environment because the CLI cannot inherit that endpoint override.
  """

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.SignalsGateway.Binding
  alias FeishuOpenAPI.TokenManager

  @spec resolve_worker_env(Binding.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def resolve_worker_env(%Binding{} = binding) do
    with {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      if Config.lark_cli_compatible?(config) do
        with {:ok, token} <- TokenManager.get_tenant_token(Config.client(config)) do
          {:ok,
           %{
             "LARKSUITE_CLI_APP_ID" => Map.fetch!(config, "appID"),
             "LARKSUITE_CLI_TENANT_ACCESS_TOKEN" => token,
             "LARKSUITE_CLI_BRAND" => Map.fetch!(config, "domain"),
             "LARKSUITE_CLI_DEFAULT_AS" => "bot",
             "LARKSUITE_CLI_STRICT_MODE" => "bot"
           }}
        end
      else
        {:ok, %{}}
      end
    end
  end

  def resolve_worker_env(_binding), do: {:error, :invalid_lark_binding}
end
