defmodule Ankole.ActorRuntime.WorkerCodexConfig do
  @moduledoc """
  AppConfigure-backed Codex runtime override for Agent Computer workers.

  Codex is a core worker capability, so this module deliberately does not define
  an enable switch. Operators may only override how Codex is configured.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Resolution
  alias Ankole.AppConfigure.Schema

  @config_override_key "agent_computer.codex.config_override"
  @modes ~w(aigateway official_subscription)
  @allowed_env_keys ~w(
    ANKOLE_AIGATEWAY_API_KEY
    OPENAI_API_KEY
    CODEX_ACCESS_TOKEN
    CODEX_CA_CERTIFICATE
    SSL_CERT_FILE
    HTTPS_PROXY
    HTTP_PROXY
    ALL_PROXY
    NO_PROXY
  )

  @doc """
  Returns the scoped AppConfigure definition for Codex config override.
  """
  @spec config_override_definition() :: Definition.t()
  def config_override_definition do
    AppConfigure.define(
      key: @config_override_key,
      scope: :scoped,
      encrypted: true,
      schema: config_override_schema(),
      default_value: nil,
      description:
        "Optional Agent Computer Codex config override. nil means worker-managed AIGateway coding profile configuration."
    )
  end

  @doc """
  Returns all AppConfigure definitions owned by the Codex worker runtime.
  """
  @spec definitions() :: [Definition.t()]
  def definitions, do: [config_override_definition()]

  @doc """
  Registers worker Codex config definitions.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions(definitions()) do
      :ok -> :ok
      {:error, {:duplicate_key, @config_override_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves the effective Codex config override for an agent.
  """
  @spec resolve_config_override(String.t()) :: {:ok, Resolution.t()} | {:error, term()} | :error
  def resolve_config_override(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered() do
      AppConfigure.resolve(config_override_definition(), agent_id: agent_uid)
    end
  end

  defp config_override_schema do
    Schema.new(fn
      nil -> {:ok, nil}
      value when is_map(value) -> normalize_config_override(value)
      _value -> {:error, :not_codex_config_override}
    end)
  end

  defp normalize_config_override(%{"mode" => mode} = config) when mode in @modes do
    allowed_keys = ~w(mode config_toml auth_json env)

    with :ok <- reject_unknown_keys(config, allowed_keys),
         {:ok, config_toml} <- optional_string(config["config_toml"]),
         {:ok, auth_json} <- optional_auth_json(config["auth_json"]),
         {:ok, env} <- optional_env(config["env"]) do
      {:ok,
       %{"mode" => mode}
       |> maybe_put("config_toml", config_toml)
       |> maybe_put("auth_json", auth_json)
       |> maybe_put("env", env)}
    end
  end

  defp normalize_config_override(%{"mode" => mode}), do: {:error, {:unsupported_mode, mode}}
  defp normalize_config_override(_config), do: {:error, :missing_mode}

  defp reject_unknown_keys(config, allowed_keys) do
    unknown_keys = Map.keys(config) -- allowed_keys

    case unknown_keys do
      [] -> :ok
      keys -> {:error, {:unknown_keys, keys}}
    end
  end

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value), do: {:ok, value}
  defp optional_string(_value), do: {:error, :invalid_string}

  defp optional_auth_json(nil), do: {:ok, nil}

  defp optional_auth_json(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_auth_json}
      _text -> {:ok, value}
    end
  end

  defp optional_auth_json(value) when is_map(value) do
    case Schema.ensure_json_value(value) do
      {:ok, _value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_auth_json, reason}}
    end
  end

  defp optional_auth_json(_value), do: {:error, :invalid_auth_json}

  defp optional_env(nil), do: {:ok, nil}

  defp optional_env(env) when is_map(env) do
    env
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc}
      when is_binary(key) and key in @allowed_env_keys and is_binary(value) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, _value}, _acc when is_binary(key) ->
        {:halt, {:error, {:unsupported_env_key, key}}}

      _entry, _acc ->
        {:halt, {:error, :invalid_env}}
    end)
  end

  defp optional_env(_env), do: {:error, :invalid_env}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
