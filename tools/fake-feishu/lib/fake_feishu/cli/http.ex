defmodule FakeFeishu.CLI.HTTP do
  @moduledoc """
  Minimal `:httpc` client for the `/sim/v1` admin API, including the SSE
  event stream. Keeping the client on `:httpc` keeps the escript free of
  HTTP dependencies.
  """

  def get(base, path) do
    request(:get, base, path, nil)
  end

  def get_binary(base, path) do
    ensure_started()

    case :httpc.request(:get, {url(base, path), []}, [], body_format: :binary) do
      {:ok, {{_http, 200, _reason}, _headers, body}} -> {:ok, body}
      {:ok, {{_http, status, _reason}, _headers, body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def post(base, path, body), do: request(:post, base, path, body)

  def delete(base, path, body \\ nil), do: request(:delete, base, path, body)

  @doc """
  Follows the SSE stream at `path`, folding `fun.(event, acc)` over decoded
  events until the server closes or `fun` returns `{:halt, acc}`.
  """
  def stream(base, path, acc, fun) do
    ensure_started()

    {:ok, ref} =
      :httpc.request(:get, {url(base, path), []}, [], sync: false, stream: :self)

    stream_loop(ref, "", acc, fun)
  end

  defp stream_loop(ref, buffer, acc, fun) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        stream_loop(ref, buffer, acc, fun)

      {:http, {^ref, :stream, chunk}} ->
        {events, buffer} = parse_sse(buffer <> chunk)

        case fold_events(events, acc, fun) do
          {:halt, acc} ->
            :httpc.cancel_request(ref)
            {:ok, acc}

          {:cont, acc} ->
            stream_loop(ref, buffer, acc, fun)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, acc}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason, acc}
    end
  end

  defp fold_events(events, acc, fun) do
    Enum.reduce_while(events, {:cont, acc}, fn event, {:cont, acc} ->
      case fun.(event, acc) do
        {:halt, acc} -> {:halt, {:halt, acc}}
        acc -> {:cont, {:cont, acc}}
      end
    end)
  end

  defp parse_sse(buffer) do
    parts = String.split(buffer, "\n\n")
    {frames, [rest]} = Enum.split(parts, -1)

    events =
      for frame <- frames,
          line <- String.split(frame, "\n"),
          String.starts_with?(line, "data: "),
          {:ok, event} <- [JSON.decode(String.trim_leading(line, "data: "))],
          do: event

    {events, rest}
  end

  defp request(method, base, path, body) do
    ensure_started()

    request =
      case body do
        nil -> {url(base, path), []}
        body -> {url(base, path), [], ~c"application/json", JSON.encode!(body)}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, response}} when status in 200..299 ->
        decode_body(response)

      {:ok, {{_http, status, _reason}, _headers, response}} ->
        {:error, {status, decoded_error(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(""), do: {:ok, nil}

  defp decode_body(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:ok, body}
    end
  end

  defp decoded_error(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => error}} -> error
      _other -> body
    end
  end

  defp url(base, path), do: String.to_charlist(String.trim_trailing(base, "/") <> path)

  defp ensure_started do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    :ok
  end
end
