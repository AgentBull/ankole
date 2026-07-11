defmodule Ankole.SignalsGateway.ActorRuntime.WorkerBrowserConfig do
  @moduledoc """
  AppConfigure-backed browser CDP override for Agent Computer workers.

  The absence of a remote config is meaningful: workers use their local
  Chromium runtime. Only a configured value switches the browser adapter to a
  remote CDP endpoint or a session-creation endpoint.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Resolution
  alias Ankole.AppConfigure.Schema

  @remote_cdp_config_key "worker.remote_browser_cdp_config"
  @local_browser_idle_ttl_ms_key "worker.local_browser_idle_ttl_ms"
  @adapter_endpoint "cdp_endpoint"
  @adapter_session_request "cdp_session_request"
  @max_connect_timeout_ms 120_000
  @min_connect_timeout_ms 1_000
  @default_local_browser_idle_ttl_ms 30 * 60 * 1_000
  @min_local_browser_idle_ttl_ms 5 * 60 * 1_000
  @max_local_browser_idle_ttl_ms 24 * 60 * 60 * 1_000

  @type remote_cdp_config :: map() | nil

  @doc """
  Returns the scoped AppConfigure definition for remote browser CDP config.
  """
  @spec remote_cdp_config_definition() :: Definition.t()
  def remote_cdp_config_definition do
    AppConfigure.define(
      key: @remote_cdp_config_key,
      scope: :scoped,
      encrypted: true,
      schema: remote_cdp_config_schema(),
      default_value: nil,
      description:
        "Optional Agent Computer remote browser CDP adapter config. nil means the worker uses local Chromium."
    )
  end

  @doc """
  Returns the scoped AppConfigure definition for local browser idle release TTL.
  """
  @spec local_browser_idle_ttl_ms_definition() :: Definition.t()
  def local_browser_idle_ttl_ms_definition do
    AppConfigure.define(
      key: @local_browser_idle_ttl_ms_key,
      scope: :scoped,
      encrypted: false,
      schema: local_browser_idle_ttl_ms_schema(),
      default_value: @default_local_browser_idle_ttl_ms,
      description:
        "Idle TTL in milliseconds before an unused local Chromium sidecar is released. Conservative by default; prevents leaks without aggressively killing browser state."
    )
  end

  @doc """
  Returns all AppConfigure definitions owned by the worker browser runtime.
  """
  @spec definitions() :: [Definition.t()]
  def definitions do
    [remote_cdp_config_definition(), local_browser_idle_ttl_ms_definition()]
  end

  @doc """
  Registers worker browser config definitions.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    Enum.reduce_while(definitions(), :ok, fn definition, :ok ->
      case AppConfigure.register_definitions([definition]) do
        :ok -> {:cont, :ok}
        {:error, {:duplicate_key, _key}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Resolves the effective remote CDP config for an agent.
  """
  @spec resolve_remote_cdp_config(String.t()) :: {:ok, Resolution.t()} | {:error, term()} | :error
  def resolve_remote_cdp_config(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered() do
      AppConfigure.resolve(remote_cdp_config_definition(), agent_id: agent_uid)
    end
  end

  @doc """
  Resolves the effective local browser idle TTL for an agent.
  """
  @spec resolve_local_browser_idle_ttl_ms(String.t()) ::
          {:ok, Resolution.t()} | {:error, term()} | :error
  def resolve_local_browser_idle_ttl_ms(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered() do
      AppConfigure.resolve(local_browser_idle_ttl_ms_definition(), agent_id: agent_uid)
    end
  end

  defp remote_cdp_config_schema do
    Schema.new(fn
      nil -> {:ok, nil}
      value when is_map(value) -> normalize_remote_cdp_config(value)
      _value -> {:error, :not_remote_cdp_config}
    end)
  end

  defp local_browser_idle_ttl_ms_schema do
    Schema.new(fn
      value
      when is_integer(value) and value >= @min_local_browser_idle_ttl_ms and
             value <= @max_local_browser_idle_ttl_ms ->
        {:ok, value}

      _value ->
        {:error,
         {:invalid_local_browser_idle_ttl_ms,
          %{
            min: @min_local_browser_idle_ttl_ms,
            max: @max_local_browser_idle_ttl_ms
          }}}
    end)
  end

  defp normalize_remote_cdp_config(%{"adapter" => @adapter_endpoint} = config) do
    allowed_keys = ~w(adapter endpoint_url headers connect_timeout_ms)

    with :ok <- reject_unknown_keys(config, allowed_keys),
         {:ok, endpoint_url} <- url(config["endpoint_url"], ~w(ws wss http https)),
         {:ok, headers} <- optional_headers(config["headers"]),
         {:ok, timeout} <- optional_timeout(config["connect_timeout_ms"]) do
      {:ok,
       %{
         "adapter" => @adapter_endpoint,
         "endpoint_url" => endpoint_url
       }
       |> maybe_put("headers", headers)
       |> maybe_put("connect_timeout_ms", timeout)}
    end
  end

  defp normalize_remote_cdp_config(
         %{"adapter" => @adapter_session_request, "request" => request} = config
       )
       when is_map(request) do
    allowed_keys = ~w(adapter request headers connect_timeout_ms)
    request_allowed_keys = ~w(url method headers body response)

    with :ok <- reject_unknown_keys(config, allowed_keys),
         :ok <- reject_unknown_keys(request, request_allowed_keys),
         {:ok, request_url} <- url(request["url"], ~w(http https)),
         {:ok, method} <- optional_method(request["method"]),
         {:ok, request_headers} <- optional_headers(request["headers"]),
         {:ok, body} <- optional_body(request["body"]),
         {:ok, response} <- optional_response(request["response"]),
         {:ok, headers} <- optional_headers(config["headers"]),
         {:ok, timeout} <- optional_timeout(config["connect_timeout_ms"]) do
      normalized_request =
        %{"url" => request_url}
        |> maybe_put("method", method)
        |> maybe_put("headers", request_headers)
        |> maybe_put("body", body)
        |> maybe_put("response", response)

      {:ok,
       %{
         "adapter" => @adapter_session_request,
         "request" => normalized_request
       }
       |> maybe_put("headers", headers)
       |> maybe_put("connect_timeout_ms", timeout)}
    end
  end

  defp normalize_remote_cdp_config(%{"adapter" => adapter}),
    do: {:error, {:unsupported_adapter, adapter}}

  defp normalize_remote_cdp_config(_config), do: {:error, :missing_adapter}

  defp reject_unknown_keys(config, allowed_keys) do
    unknown_keys = Map.keys(config) -- allowed_keys

    case unknown_keys do
      [] -> :ok
      keys -> {:error, {:unknown_keys, keys}}
    end
  end

  defp url(value, allowed_schemes) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(host) ->
        if scheme in allowed_schemes do
          {:ok, URI.to_string(uri)}
        else
          {:error, {:invalid_url_scheme, scheme}}
        end

      {:ok, %URI{scheme: scheme}} ->
        {:error, {:invalid_url_scheme, scheme}}

      {:error, reason} ->
        {:error, {:invalid_url, reason}}
    end
  end

  defp url(_value, _allowed_schemes), do: {:error, :invalid_url}

  defp optional_headers(nil), do: {:ok, nil}

  defp optional_headers(headers) when is_map(headers) do
    headers
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) and key != "" and is_binary(value) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      _entry, _acc ->
        {:halt, {:error, :invalid_headers}}
    end)
  end

  defp optional_headers(_headers), do: {:error, :invalid_headers}

  defp optional_timeout(nil), do: {:ok, nil}

  defp optional_timeout(value)
       when is_integer(value) and value >= @min_connect_timeout_ms and
              value <= @max_connect_timeout_ms,
       do: {:ok, value}

  defp optional_timeout(_value), do: {:error, :invalid_connect_timeout_ms}

  defp optional_method(nil), do: {:ok, nil}
  defp optional_method(method) when method in ["GET", "POST"], do: {:ok, method}
  defp optional_method(_method), do: {:error, :invalid_method}

  defp optional_body(nil), do: {:ok, nil}
  defp optional_body(body) when is_map(body), do: {:ok, body}
  defp optional_body(_body), do: {:error, :invalid_body}

  defp optional_response(nil), do: {:ok, nil}

  defp optional_response(%{"type" => "text"} = response) do
    with :ok <- reject_unknown_keys(response, ~w(type)) do
      {:ok, %{"type" => "text"}}
    end
  end

  defp optional_response(%{"type" => "json", "path" => path} = response) when is_list(path) do
    with :ok <- reject_unknown_keys(response, ~w(type path)),
         true <- Enum.all?(path, &(is_binary(&1) and &1 != "")) do
      {:ok, %{"type" => "json", "path" => path}}
    else
      false -> {:error, :invalid_response_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_response(%{"type" => type}), do: {:error, {:invalid_response_type, type}}
  defp optional_response(_response), do: {:error, :invalid_response}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
