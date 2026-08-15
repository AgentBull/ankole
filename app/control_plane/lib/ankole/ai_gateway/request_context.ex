defmodule Ankole.AIGateway.RequestContext do
  @moduledoc false

  alias Ankole.Observability.UserID

  @forwarded_headers ~w(
    originator
    user-agent
    session-id
    session_id
    thread-id
    traceparent
    x-codex-beta-features
    x-codex-turn-metadata
    x-codex-turn-state
    x-codex-window-id
    x-client-request-id
    x-openai-internal-codex-responses-lite
    x-responsesapi-include-timing-metrics
    x-session-id
    version
  )

  # Headers that identify the calling client to the upstream Provider. They are
  # forwarded whenever the caller sent them: a caller that sends none needs no
  # rule, and a caller that sends them is asking for its own identity to reach
  # the model. `traceparent` stays out; it is this instance's trace, not the
  # caller's identity.
  @client_identity_headers [
    {"originator", "Originator"},
    {"user-agent", "User-Agent"},
    {"session_id", "Session_id"},
    {"session-id", "Session-Id"},
    {"x-session-id", "X-Session-Id"},
    {"thread-id", "Thread-Id"},
    {"x-client-request-id", "X-Client-Request-Id"},
    {"x-codex-beta-features", "X-Codex-Beta-Features"},
    {"x-codex-turn-metadata", "X-Codex-Turn-Metadata"},
    {"x-codex-turn-state", "X-Codex-Turn-State"},
    {"x-codex-window-id", "X-Codex-Window-Id"},
    {"x-openai-internal-codex-responses-lite", "X-Openai-Internal-Codex-Responses-Lite"},
    {"x-responsesapi-include-timing-metrics", "X-Responsesapi-Include-Timing-Metrics"},
    {"version", "Version"}
  ]

  @doc """
  Returns the caller's identity headers in Provider wire form.
  """
  @spec client_identity_headers(map()) :: [{String.t(), String.t()}]
  def client_identity_headers(request_context) when is_map(request_context) do
    inbound = Map.get(request_context, "headers", %{})

    for {source, target} <- @client_identity_headers,
        value = Map.get(inbound, source),
        is_binary(value) and value != "" do
      {target, value}
    end
  end

  def client_identity_headers(_request_context), do: []

  @session_headers ~w(x-session-id session_id session-id thread-id)
  @observability_user_header "x-ankole-observability-user-id"

  @doc "Returns the client session headers in precedence order."
  @spec session_header_names() :: [String.t()]
  def session_header_names, do: @session_headers

  @spec from_headers([{String.t(), String.t()}], String.t()) :: map()
  def from_headers(headers, downstream_transport) when is_list(headers) do
    safe_headers =
      headers
      |> Enum.reduce(%{}, fn {name, value}, acc ->
        normalized = String.downcase(name)

        if normalized in @forwarded_headers and is_binary(value) and value != "" do
          Map.put_new(acc, normalized, value)
        else
          acc
        end
      end)

    %{
      "headers" => safe_headers,
      "downstream_transport" => downstream_transport
    }
    |> put_observability_user_id(headers)
  end

  @doc false
  @spec observability_user_id(map()) :: {:ok, String.t() | nil} | :missing
  def observability_user_id(%{} = context) do
    if Map.has_key?(context, "observability_user_id") do
      case Map.get(context, "observability_user_id") do
        nil ->
          {:ok, nil}

        value when is_binary(value) ->
          case UserID.normalize(value) do
            {:ok, user_id} -> {:ok, user_id}
            :error -> :missing
          end

        _invalid ->
          :missing
      end
    else
      :missing
    end
  end

  def observability_user_id(_context), do: :missing

  @spec prepare(map(), map()) :: map()
  def prepare(context, request) when is_map(context) and is_map(request) do
    natural_cache_key = natural_cache_key(context, request)
    cache_key = natural_cache_key || Ankole.Ecto.UUIDv7.autogenerate()

    context
    |> Map.put("cache_key", cache_key)
    |> maybe_put_affinity(natural_cache_key, cache_key)
  end

  def prepare(_context, request) when is_map(request), do: prepare(%{}, request)

  @doc """
  Returns the client-declared conversation identity, or nil.

  `prompt_cache_key` is only a cache-routing and credential-affinity input. It
  is not a conversation identity and must not become an observability session.
  """
  @spec session_key(map(), map()) :: String.t() | nil
  def session_key(context, request) when is_map(context) and is_map(request) do
    text(Map.get(request, "session_id")) ||
      Enum.find_value(@session_headers, &header(context, &1)) ||
      text(get_in(request, ["metadata", "conversation_id"])) ||
      text(get_in(request, ["metadata", "thread_id"])) ||
      text(get_in(request, ["metadata", "session_id"]))
  end

  defp natural_cache_key(context, request) do
    text(Map.get(request, "prompt_cache_key")) || session_key(context, request)
  end

  defp maybe_put_affinity(
         %{"downstream_transport" => "websocket"} = context,
         _natural_cache_key,
         cache_key
       ),
       do: Map.put(context, "affinity_key", cache_key)

  defp maybe_put_affinity(context, natural_cache_key, _cache_key)
       when is_binary(natural_cache_key),
       do: Map.put(context, "affinity_key", natural_cache_key)

  defp maybe_put_affinity(context, _natural_cache_key, _cache_key), do: context

  defp put_observability_user_id(context, headers) do
    case Enum.find_value(headers, fn
           {name, value} when is_binary(name) and is_binary(value) ->
             if String.downcase(name) == @observability_user_header,
               do: {:found, UserID.decode_carrier(value)}

           _header ->
             nil
         end) do
      {:found, {:ok, user_id}} -> Map.put(context, "observability_user_id", user_id)
      _missing_or_invalid -> context
    end
  end

  defp header(context, name), do: get_in(context, ["headers", name]) |> text()

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil
end
