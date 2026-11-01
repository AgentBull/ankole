defmodule Ankole.Plugins.DiscordAdapter.Config do
  def platform_application(config) do
    case Ankole.Plugins.DiscordAdapter.Client.current_application(client(config)) do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, "discord:" <> id}
      {:error, _} = error -> error
      _ -> {:error, :platform_application_identity_unavailable}
    end
  end

  @moduledoc "Validation and runtime helpers for the first-party Discord adapter."

  alias Ankole.Signals.Bindings
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.DiscordAdapter.Client
  alias Ankole.Plugins.MapHelpers

  @key_pattern ~r/\Asignals\.discord\.bindings\.[A-Za-z0-9_.:-]+\z/

  @type t :: %{required(String.t()) => String.t()}

  defmodule Runtime do
    @moduledoc false

    @enforce_keys [:bot_token]
    defstruct [:bot_token]

    @type t :: %__MODULE__{bot_token: String.t()}
  end

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals.discord.bindings.*",
        console_writable: false,
        key_pattern: @key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_binding_config/1),
        description: "Encrypted Discord bot binding configuration."
      )
    ]
  end

  @doc """
  Builds the stable AppConfigure key owned by one Agent binding.

  The digest gives each `(agent, binding)` pair its own key; a name-only key
  would collide across Agents that use the same binding name, so one Agent's
  token write would replace another's.
  """
  @spec binding_config_key(String.t(), String.t()) :: String.t()
  def binding_config_key(tenant_id, binding_id)
      when is_binary(tenant_id) and is_binary(binding_id) do
    Ankole.Signals.Bindings.binding_config_key(
      "signals.discord.bindings",
      tenant_id,
      binding_id
    )
  end

  @spec validate_binding_config(term()) :: {:ok, t()} | {:error, term()}
  def validate_binding_config(value) when is_map(value) do
    with {:ok, token} <- MapHelpers.required_string(value, "botToken") do
      {:ok, %{"botToken" => token}}
    end
  end

  def validate_binding_config(_value), do: {:error, :invalid_discord_binding_config}

  @spec validate_binding_assignment(String.t(), String.t(), t()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(agent_uid, binding_name, config)
      when is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    fingerprint = secret_fingerprint(config)

    Ankole.Signals.list_bindings!(
      query: [
        filter: [
          adapter: "discord",
          enabled: true,
          or: [[agent_uid: [not_eq: agent_uid]], [name: [not_eq: binding_name]]]
        ]
      ]
    )
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case Bindings.binding_config_in_tx(binding, __MODULE__) do
        {:ok, other} ->
          if secret_fingerprint(other) == fingerprint do
            {:halt, {:error, {:discord_bot_token_already_bound, binding.agent_uid, binding.name}}}
          else
            {:cont, :ok}
          end

        :error ->
          {:halt,
           {:error, {:discord_binding_config_unavailable, binding.agent_uid, binding.name}}}

        {:error, reason} ->
          {:halt,
           {:error,
            {:discord_binding_config_unavailable, binding.agent_uid, binding.name, reason}}}
      end
    end)
  end

  @spec client(t() | Runtime.t(), keyword()) :: Client.t()
  def client(config, opts \\ []) do
    client_opts =
      :ankole
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:client_opts, [])

    Client.new(bot_token(config), Keyword.merge(client_opts, opts))
  end

  @doc """
  Returns the raw bot token. The gateway IDENTIFY and RESUME payloads carry the
  token itself, so unlike the REST client they cannot take a prepared header.
  """
  @spec bot_token(t() | Runtime.t()) :: String.t()
  def bot_token(%Runtime{bot_token: token}), do: token
  def bot_token(config) when is_map(config), do: Map.fetch!(config, "botToken")

  @spec secret_fingerprint(t() | Runtime.t()) :: String.t()
  def secret_fingerprint(config) do
    :sha256
    |> :crypto.hash(bot_token(config))
    |> Base.encode16(case: :lower)
  end

  def runtime_config(config), do: %Runtime{bot_token: Map.fetch!(config, "botToken")}
end

defimpl Inspect, for: Ankole.Plugins.DiscordAdapter.Config.Runtime do
  import Inspect.Algebra

  def inspect(_config, _opts) do
    concat(["#Ankole.Plugins.DiscordAdapter.Config.Runtime<", "[REDACTED]", ">"])
  end
end
