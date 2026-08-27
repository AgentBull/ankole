defmodule Ankole.Plugins.DiscordAdapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party Discord adapter."

  import Ecto.Query, warn: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.DiscordAdapter.Client
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.Binding

  @key_pattern ~r/\Asignals_gateway\.discord\.bindings\.[A-Za-z0-9_.:-]+\z/

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
        id: "signals_gateway.discord.bindings.*",
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
  def binding_config_key(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    id =
      [agent_uid, binding_name]
      |> Ankole.JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "signals_gateway.discord.bindings.#{id}"
  end

  @spec validate_binding_config(term()) :: {:ok, t()} | {:error, term()}
  def validate_binding_config(value) when is_map(value) do
    with {:ok, token} <- MapHelpers.required_string(value, "botToken") do
      {:ok, %{"botToken" => token}}
    end
  end

  def validate_binding_config(_value), do: {:error, :invalid_discord_binding_config}

  @spec validate_binding_assignment(module(), String.t(), String.t(), t()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(repo, agent_uid, binding_name, config)
      when is_atom(repo) and is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    fingerprint = secret_fingerprint(config)

    Binding
    |> where(
      [binding],
      binding.adapter == "discord" and binding.enabled == true and
        (binding.agent_uid != ^agent_uid or binding.name != ^binding_name)
    )
    |> repo.all()
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case load_config_ref_in_tx(repo, binding.config_ref) do
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

  @spec load_config_ref(String.t()) :: {:ok, Runtime.t()} | :error | {:error, term()}
  def load_config_ref(config_ref) when is_binary(config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_by_key(key),
         {:ok, config} <- validate_binding_config(value) do
      {:ok, runtime_config(config)}
    end
  end

  def load_config_ref(_config_ref), do: {:error, :invalid_config_ref}

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

  defp load_config_ref_in_tx(repo, config_ref) do
    with {:ok, key} <- app_config_key(config_ref),
         {:ok, value} <- AppConfigure.get_global_by_key_in_tx(repo, key) do
      validate_binding_config(value)
    end
  end

  defp app_config_key("app-config://" <> key), do: {:ok, key}
  defp app_config_key("app-config:" <> key), do: {:ok, key}
  defp app_config_key(key) when is_binary(key), do: {:ok, key}

  defp runtime_config(config), do: %Runtime{bot_token: Map.fetch!(config, "botToken")}
end

defimpl Inspect, for: Ankole.Plugins.DiscordAdapter.Config.Runtime do
  import Inspect.Algebra

  def inspect(_config, _opts) do
    concat(["#Ankole.Plugins.DiscordAdapter.Config.Runtime<", "[REDACTED]", ">"])
  end
end
