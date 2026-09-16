defmodule Ankole.Plugins.WhatsAppAdapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party WhatsApp adapter."

  import Ecto.Query, warn: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WhatsAppAdapter.Client
  alias Ankole.SignalsGateway.Binding

  @key_pattern ~r/\Asignals_gateway\.whatsapp\.bindings\.[A-Za-z0-9_.:-]+\z/
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
        id: "signals_gateway.whatsapp.bindings.*",
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
  def binding_config_key(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    id =
      [agent_uid, binding_name]
      |> Ankole.JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "signals_gateway.whatsapp.bindings.#{id}"
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

  @doc """
  Checks one saved binding against every other enabled WhatsApp binding.

  Two enabled bindings on one phone number would both answer every message. Two
  enabled bindings on one Meta App share the webhook URL, so they must also
  agree on the App secret and the verify token; otherwise the second save would
  make one of them reject each delivery.
  """
  @spec validate_binding_assignment(module(), String.t(), String.t(), t()) ::
          :ok | {:error, term()}
  def validate_binding_assignment(repo, agent_uid, binding_name, config)
      when is_atom(repo) and is_binary(agent_uid) and is_binary(binding_name) and is_map(config) do
    Binding
    |> where(
      [binding],
      binding.adapter == "whatsapp" and binding.enabled == true and
        (binding.agent_uid != ^agent_uid or binding.name != ^binding_name)
    )
    |> repo.all()
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case load_config_ref_in_tx(repo, binding.config_ref) do
        {:ok, other} ->
          compare_bindings(config, other, binding)

        :error ->
          {:halt,
           {:error, {:whatsapp_binding_config_unavailable, binding.agent_uid, binding.name}}}

        {:error, reason} ->
          {:halt,
           {:error,
            {:whatsapp_binding_config_unavailable, binding.agent_uid, binding.name, reason}}}
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

  defp compare_bindings(config, other, binding) do
    cond do
      phone_number_id(other) == phone_number_id(config) ->
        {:halt, {:error, {:whatsapp_phone_number_already_bound, binding.agent_uid, binding.name}}}

      app_id(other) == app_id(config) and
          (app_secret(other) != app_secret(config) or
             verify_token(other) != verify_token(config)) ->
        {:halt, {:error, {:whatsapp_app_credentials_mismatch, binding.agent_uid, binding.name}}}

      true ->
        {:cont, :ok}
    end
  end

  defp validate_numeric_id(value, error) do
    if Regex.match?(@numeric_id_pattern, value), do: :ok, else: {:error, error}
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
