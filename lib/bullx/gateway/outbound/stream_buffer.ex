defmodule BullX.Gateway.Outbound.StreamBuffer do
  @moduledoc false

  alias BullX.Gateway.{JSON, Outbound.Store}

  @flush_sentinel {:__bullx_gateway_stream_flush__, :complete}

  @spec wrap(String.t(), Enumerable.t()) :: Enumerable.t()
  def wrap(stream_id, enumerable) when is_binary(stream_id) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds(), :second)

    enumerable
    |> Stream.concat([@flush_sentinel])
    |> Stream.transform("", fn chunk, pending ->
      {batches, pending} = batches(chunk, pending)

      Enum.each(batches, &append(stream_id, &1, expires_at))

      {batches, pending}
    end)
  end

  defp batches(@flush_sentinel, pending), do: flush_text(pending)

  defp batches(chunk, pending) when is_binary(chunk) do
    pending = pending <> chunk

    case text_flush?(pending) do
      true -> {[%{"kind" => "text", "text" => pending}], ""}
      false -> {[], pending}
    end
  end

  defp batches(chunk, pending) do
    case JSON.stringify_keys(chunk) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        batches(text, pending)

      {:ok, %{"kind" => "text", "text" => text}} when is_binary(text) ->
        batches(text, pending)

      {:ok, chunk} when is_map(chunk) ->
        flush_pending_before(chunk, pending)

      {:ok, chunk} when is_list(chunk) ->
        flush_pending_before(%{"kind" => "batch", "items" => chunk}, pending)

      _other ->
        {[], pending}
    end
  end

  defp flush_pending_before(chunk, ""), do: {[chunk], ""}

  defp flush_pending_before(chunk, pending),
    do: {[%{"kind" => "text", "text" => pending}, chunk], ""}

  defp flush_text(""), do: {[], ""}
  defp flush_text(pending), do: {[%{"kind" => "text", "text" => pending}], ""}

  defp text_flush?(text), do: String.contains?(text, "\n") or String.length(text) > 10

  defp append(stream_id, chunk, expires_at),
    do: Store.append_stream_chunk(stream_id, chunk, expires_at)

  defp ttl_seconds do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:stream_buffer_ttl_seconds, 86_400)
  end
end
