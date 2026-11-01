defmodule Ankole.Plugins.WhatsAppAdapter.Config do
  def platform_application(config), do: {:ok, "whatsapp:" <> Map.fetch!(config, "phoneNumberId")}
  @moduledoc "Validation and runtime helpers for the first-party WhatsApp adapter."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WhatsAppAdapter.Client
  alias Ankole.Signals.Binding

  @key_pattern ~r/\Asignals\.whatsapp\.bindings\.[A-Za-z0-9_.:-]+\z/
  @numeric_id_pattern ~r/\A[0-9]{1,32}\z/

  @type t :: %{required(String.t()) => String.t()}

  defmodule Runtime do
    @moduledoc false

    @enforce_keys [:app_id, :app_secret, :verify_token, :phone_number_id, :access_token]
    defstruct [:app_id, :app_secret, :verify_token, :phone_number_id, :access_token]

    @type t :: %__MODULE__{
            app_id: String.t(),
            app_secret: String.t(),
            verify_token: String.t(),
            phone_number_id: String.t(),
            access_token: String.t()
          }
  end

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "signals.whatsapp.bindings.*",
        console_writable: false,
        key_pattern: @key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_binding_config/1),
        description: "Encrypted WhatsApp Cloud API binding configuration."
      )
    ]
  end

  @doc """
  Builds the stable AppConfigure key owned by one Agent binding.

  The digest gives each `(agent, binding)` pair its own key; a name-only key
  would collide across Agents that use the same binding name.
  """
  @spec binding_config_key(String.t(), String.t()) :: String.t()
  def binding_config_key(tenant_id, binding_id)
      when is_binary(tenant_id) and is_binary(binding_id) do
    Ankole.Signals.Bindings.binding_config_key(
      "signals.whatsapp.bindings",
      tenant_id,
      binding_id
    )
  end

  @spec validate_binding_config(term()) :: {:ok, t()} | {:error, term()}
  def validate_binding_config(value) when is_map(value) do
    with {:ok, app_id} <- MapHelpers.required_string(value, "appId"),
         :ok <- validate_numeric_id(app_id, :invalid_whatsapp_app_id),
         {:ok, app_secret} <- MapHelpers.required_string(value, "appSecret"),
         {:ok, verify_token} <- MapHelpers.required_string(value, "verifyToken"),
         {:ok, phone_number_id} <- MapHelpers.required_string(value, "phoneNumberId"),
         :ok <- validate_numeric_id(phone_number_id, :invalid_whatsapp_phone_number_id),
         {:ok, access_token} <- MapHelpers.required_string(value, "accessToken") do
      {:ok,
       %{
         "appId" => app_id,
         "appSecret" => app_secret,
         "verifyToken" => verify_token,
         "phoneNumberId" => phone_number_id,
         "accessToken" => access_token
       }}
    end
  end

  def validate_binding_config(_value), do: {:error, :invalid_whatsapp_binding_config}

  @spec client(t() | Runtime.t(), keyword()) :: Client.t()
  def client(config, opts \\ []) do
    client_opts =
      :ankole
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:client_opts, [])

    Client.new(access_token(config), Keyword.merge(client_opts, opts))
  end

  @spec app_id(t() | Runtime.t()) :: String.t()
  def app_id(%Runtime{app_id: value}), do: value
  def app_id(config) when is_map(config), do: Map.fetch!(config, "appId")

  @spec app_secret(t() | Runtime.t()) :: String.t()
  def app_secret(%Runtime{app_secret: value}), do: value
  def app_secret(config) when is_map(config), do: Map.fetch!(config, "appSecret")

  @spec verify_token(t() | Runtime.t()) :: String.t()
  def verify_token(%Runtime{verify_token: value}), do: value
  def verify_token(config) when is_map(config), do: Map.fetch!(config, "verifyToken")

  @spec phone_number_id(t() | Runtime.t()) :: String.t()
  def phone_number_id(%Runtime{phone_number_id: value}), do: value
  def phone_number_id(config) when is_map(config), do: Map.fetch!(config, "phoneNumberId")

  defp access_token(%Runtime{access_token: value}), do: value
  defp access_token(config) when is_map(config), do: Map.fetch!(config, "accessToken")

  @doc "Rejects different webhook credentials for bindings that share one Meta App."
  @spec validate_binding_pair(Binding.t(), t(), t()) :: :ok | {:error, term()}
  def validate_binding_pair(binding, config, other) do
    if app_id(other) == app_id(config) and
         (app_secret(other) != app_secret(config) or
            verify_token(other) != verify_token(config)) do
      {:error, {:whatsapp_app_credentials_mismatch, binding.agent_uid, binding.name}}
    else
      :ok
    end
  end

  defp validate_numeric_id(value, error) do
    if Regex.match?(@numeric_id_pattern, value), do: :ok, else: {:error, error}
  end

  def runtime_config(config) do
    %Runtime{
      app_id: Map.fetch!(config, "appId"),
      app_secret: Map.fetch!(config, "appSecret"),
      verify_token: Map.fetch!(config, "verifyToken"),
      phone_number_id: Map.fetch!(config, "phoneNumberId"),
      access_token: Map.fetch!(config, "accessToken")
    }
  end
end

defimpl Inspect, for: Ankole.Plugins.WhatsAppAdapter.Config.Runtime do
  import Inspect.Algebra

  def inspect(config, opts) do
    concat([
      "#Ankole.Plugins.WhatsAppAdapter.Config.Runtime<",
      to_doc(
        %{app_id: config.app_id, phone_number_id: config.phone_number_id, secrets: "[REDACTED]"},
        opts
      ),
      ">"
    ])
  end
end
