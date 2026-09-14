defmodule Ankole.Plugins.LineAdapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party LINE adapter."

  import Ecto.Query, warn: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.LineAdapter.Client
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.Binding

  @key_pattern ~r/\Asignals_gateway\.line\.bindings\.[A-Za-z0-9_.:-]+\z/
  @channel_id_pattern ~r/\A[0-9]{1,32}\z/

  @type t :: %{required(String.t()) => String.t()}

  defmodule Runtime do
    @moduledoc false

    @enforce_keys [:channel_id, :channel_secret, :channel_access_token]
    defstruct [:channel_id, :channel_secret, :channel_access_token]

    @type t :: %__MODULE__{
            channel_id: String.t(),
            channel_secret: String.t(),
            channel_access_token: String.t()
          }
  end

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals_gateway.line.bindings.*",
        key_pattern: @key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_binding_config/1),
        description: "Encrypted LINE channel binding configuration."
      )
    ]
  end

  @doc """
  Builds the stable AppConfigure key owned by one Agent binding.

  The digest gives each `(agent, binding)` pair its own key; a name-only key
  would collide across Agents that use the same binding name.
  """
  @spec binding_config_key(String.t(), String.t()) :: String.t()
  def binding_config_key(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    id =
      [agent_uid, binding_name]
      |> Ankole.JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "signals_gateway.line.bindings.#{id}"
  end

  @spec validate_binding_config(term()) :: {:ok, t()} | {:error, term()}
  def validate_binding_config(value) when is_map(value) do
    with {:ok, channel_id} <- MapHelpers.required_string(value, "channelId"),
         :ok <- validate_channel_id(channel_id),
         {:ok, secret} <- MapHelpers.required_string(value, "channelSecret"),
         {:ok, token} <- MapHelpers.required_string(value, "channelAccessToken") do
      {:ok,
       %{
         "channelId" => channel_id,
         "channelSecret" => secret,
         "channelAccessToken" => token
       }}
    end
  end

  def validate_binding_config(_value), do: {:error, :invalid_line_binding_config}

  # One LINE channel is one Official Account. Two enabled bindings on the same
  # channel would both answer every message, so the second save is refused.
  @spec validate_binding_assignment(module(), String.t(), String.t(), t()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(repo, agent_uid, binding_name, config)
      when is_atom(repo) and is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    channel_id = channel_id(config)

    Binding
    |> where(
      [binding],
      binding.adapter == "line" and binding.enabled == true and
        (binding.agent_uid != ^agent_uid or binding.name != ^binding_name)
    )
    |> repo.all()
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case load_config_ref_in_tx(repo, binding.config_ref) do
        {:ok, other} ->
          if channel_id(other) == channel_id do
            {:halt, {:error, {:line_channel_already_bound, binding.agent_uid, binding.name}}}
          else
            {:cont, :ok}
          end

        :error ->
          {:halt, {:error, {:line_binding_config_unavailable, binding.agent_uid, binding.name}}}

        {:error, reason} ->
          {:halt,
           {:error, {:line_binding_config_unavailable, binding.agent_uid, binding.name, reason}}}
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

    Client.new(channel_access_token(config), Keyword.merge(client_opts, opts))
  end

  @spec channel_id(t() | Runtime.t()) :: String.t()
  def channel_id(%Runtime{channel_id: value}), do: value
  def channel_id(config) when is_map(config), do: Map.fetch!(config, "channelId")

  @spec channel_secret(t() | Runtime.t()) :: String.t()
  def channel_secret(%Runtime{channel_secret: value}), do: value
  def channel_secret(config) when is_map(config), do: Map.fetch!(config, "channelSecret")

  defp channel_access_token(%Runtime{channel_access_token: value}), do: value

  defp channel_access_token(config) when is_map(config),
    do: Map.fetch!(config, "channelAccessToken")

  defp validate_channel_id(channel_id) do
    if Regex.match?(@channel_id_pattern, channel_id),
      do: :ok,
      else: {:error, :invalid_line_channel_id}
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

  defp runtime_config(config) do
    %Runtime{
      channel_id: Map.fetch!(config, "channelId"),
      channel_secret: Map.fetch!(config, "channelSecret"),
      channel_access_token: Map.fetch!(config, "channelAccessToken")
    }
  end
end

defimpl Inspect, for: Ankole.Plugins.LineAdapter.Config.Runtime do
  import Inspect.Algebra

  def inspect(config, opts) do
    concat([
      "#Ankole.Plugins.LineAdapter.Config.Runtime<",
      to_doc(%{channel_id: config.channel_id, secrets: "[REDACTED]"}, opts),
      ">"
    ])
  end
end
