defmodule Ankole.AIGateway.SSE do
  @moduledoc """
  Parses Server-Sent Events frames from arbitrary byte chunks.

  Upstream providers stream with slightly different SSE formatting. This parser
  handles LF/CRLF, comments, optional spaces after `:`, multi-line `data:`
  fields, and the OpenAI-style `[DONE]` sentinel before provider-specific JSON
  decoding runs.
  """

  @type event :: :done | map()
  @type t :: %{buffer: String.t()}

  @doc "Creates an empty SSE parser state."
  @spec new() :: t()
  def new, do: %{buffer: ""}

  @doc """
  Adds one byte chunk and returns every complete SSE event parsed from it.
  """
  @spec feed(t(), binary()) :: {:ok, [event()], t()}
  def feed(%{buffer: buffer} = state, chunk) when is_binary(chunk) do
    buffer =
      (buffer <> chunk)
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    {frames, buffer} = take_frames(buffer, [])

    {:ok, Enum.flat_map(frames, &parse_frame/1), %{state | buffer: buffer}}
  end

  @doc """
  Flushes the parser when the upstream stream closes.

  A non-empty partial frame is reported as an error because accepting it would
  hide a truncated provider stream.
  """
  @spec finish(t()) :: {:ok, [event()], t()} | {:error, :incomplete_sse_event}
  def finish(%{buffer: ""} = state), do: {:ok, [], state}

  def finish(%{buffer: buffer} = state) do
    case String.trim(buffer) do
      "" -> {:ok, [], %{state | buffer: ""}}
      _buffer -> {:error, :incomplete_sse_event}
    end
  end

  defp take_frames(buffer, acc) do
    case :binary.match(buffer, "\n\n") do
      {index, 2} ->
        frame = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 2, byte_size(buffer) - index - 2)
        take_frames(rest, [frame | acc])

      :nomatch ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp parse_frame(frame) do
    lines = String.split(frame, "\n")

    parsed =
      Enum.reduce(lines, %{data: [], event: nil}, fn line, acc ->
        cond do
          line == "" ->
            acc

          String.starts_with?(line, ":") ->
            acc

          true ->
            parse_field(line, acc)
        end
      end)

    data =
      parsed.data
      |> Enum.reverse()
      |> Enum.join("\n")

    cond do
      data == "" ->
        []

      data == "[DONE]" ->
        [:done]

      is_binary(parsed.event) ->
        [%{"event" => parsed.event, "data" => data}]

      true ->
        [%{"data" => data}]
    end
  end

  defp parse_field(line, acc) do
    {field, value} =
      case String.split(line, ":", parts: 2) do
        [field, value] -> {field, String.trim_leading(value, " ")}
        [field] -> {field, ""}
      end

    case field do
      "data" -> %{acc | data: [value | acc.data]}
      "event" -> %{acc | event: value}
      _field -> acc
    end
  end
end
