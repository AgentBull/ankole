defmodule Ankole.AIGateway.RequestContext do
  @moduledoc false

  @forwarded_headers ~w(
    originator
    user-agent
    session-id
    session_id
    thread-id
    x-codex-beta-features
    x-codex-turn-metadata
    x-codex-turn-state
    x-client-request-id
    x-openai-internal-codex-responses-lite
    x-responsesapi-include-timing-metrics
    x-session-id
    version
  )

  @session_headers ~w(x-session-id session_id session-id thread-id)

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
  end

  @spec prepare(map(), map()) :: map()
  def prepare(context, request) when is_map(context) and is_map(request) do
    natural_cache_key = natural_cache_key(context, request)
    cache_key = natural_cache_key || Ankole.Ecto.UUIDv7.autogenerate()

    context
    |> Map.put("cache_key", cache_key)
    |> maybe_put_affinity(natural_cache_key, cache_key)
  end

  def prepare(_context, request) when is_map(request), do: prepare(%{}, request)

  defp natural_cache_key(context, request) do
    text(Map.get(request, "prompt_cache_key")) ||
      text(Map.get(request, "session_id")) ||
      Enum.find_value(@session_headers, &header(context, &1)) ||
      text(get_in(request, ["metadata", "conversation_id"])) ||
      text(get_in(request, ["metadata", "thread_id"])) ||
      text(get_in(request, ["metadata", "session_id"]))
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

  defp header(context, name), do: get_in(context, ["headers", name]) |> text()

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil
end
