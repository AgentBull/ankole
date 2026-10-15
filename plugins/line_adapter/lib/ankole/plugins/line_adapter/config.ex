defmodule Ankole.Plugins.LineAdapter.Config do
  def platform_application(config), do: {:ok, "line:" <> Map.fetch!(config, "channelId")}
  @moduledoc "Validation and runtime helpers for the first-party LINE adapter."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.LineAdapter.Client
  alias Ankole.Plugins.MapHelpers

  @key_pattern ~r/\Asignals\.line\.bindings\.[A-Za-z0-9_.:-]+\z/
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
        id: "signals.line.bindings.*",
        console_writable: false,
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

    "signals.line.bindings.#{id}"
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

  def runtime_config(config) do
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
