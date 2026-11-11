defmodule Ankole.Kernel.JSON do
  @moduledoc """
  Bounded JSON transport for documents whose nodes contain both objects and arrays.

  Torque handles ordinary payloads. OTP's JSON codec handles deeper payloads,
  with a 512-container limit that includes document nodes and transport envelopes.
  The document codec separately enforces its 128-level tree limit.

  Callers pass Torque options on both paths: `dirty: true` for encoding a
  known-large term, and `strings: :copy` for decoding a frame whose parts the
  caller keeps long after the frame itself.
  """
  @max_depth 512

  def decode(data, opts \\ []) when is_binary(data) do
    case Torque.decode(data, opts) do
      {:error, :nesting_too_deep} -> decode_deep(data, 0, opts[:strings] == :copy)
      result -> result
    end
  end

  def decode!(data, opts \\ []) do
    case decode(data, opts) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "decode error: #{inspect(reason)}"
    end
  end

  def encode(value, opts \\ []) do
    case Torque.encode(value, opts) do
      {:error, :nesting_too_deep} -> {:ok, value |> encode_deep(0, opts) |> IO.iodata_to_binary()}
      result -> result
    end
  catch
    :nesting_too_deep -> {:error, :nesting_too_deep}
    {:encode_error, reason} -> {:error, reason}
  end

  def encode!(value, opts \\ []) do
    case encode(value, opts) do
      {:ok, json} -> json
      {:error, reason} -> raise ArgumentError, "encode error: #{inspect(reason)}"
    end
  end

  defp encode_deep(value, depth, opts) when is_map(value) and not is_struct(value) do
    if depth >= @max_depth, do: throw(:nesting_too_deep)
    Enum.each(value, fn {key, _} -> encode_leaf(%{key => nil}, 0, []) end)
    JSON.protocol_encode(value, fn child, _ -> encode_deep(child, depth + 1, opts) end)
  end

  defp encode_deep(value, depth, opts) when is_list(value) do
    if depth >= @max_depth, do: throw(:nesting_too_deep)
    JSON.protocol_encode(value, fn child, _ -> encode_deep(child, depth + 1, opts) end)
  end

  defp encode_deep(value, depth, opts), do: encode_leaf(value, depth, opts)

  defp encode_leaf(value, depth, opts) do
    case Torque.encode(value, opts) do
      {:ok, json} ->
        if is_tuple(value) or is_struct(value) do
          case decode_deep(json, depth) do
            {:ok, _} -> :ok
            {:error, reason} -> throw({:encode_error, reason})
          end
        end

        json

      {:error, reason} ->
        throw({:encode_error, reason})
    end
  end

  defp decode_deep(data, initial_depth, copy_strings? \\ false) do
    start = fn {depth, _} ->
      if depth >= @max_depth, do: throw(:nesting_too_deep)
      {depth + 1, []}
    end

    # OTP returns strings and keys as slices of `data`; copying detaches them.
    key = if copy_strings?, do: &:binary.copy/1, else: & &1

    decoders = [
      array_start: start,
      array_push: fn value, {depth, values} -> {depth, [value | values]} end,
      array_finish: fn {_, values}, parent -> {Enum.reverse(values), parent} end,
      object_start: start,
      object_push: fn k, value, {depth, values} -> {depth, [{key.(k), value} | values]} end,
      object_finish: fn {_, values}, parent -> {Map.new(Enum.reverse(values)), parent} end
    ]

    decoders = if copy_strings?, do: [string: &:binary.copy/1] ++ decoders, else: decoders

    case JSON.decode(data, {initial_depth, []}, decoders) do
      {value, _, rest} ->
        if rest =~ ~r/\A[ \t\n\r]*\z/, do: {:ok, value}, else: {:error, :trailing_data}

      {:error, _} = error ->
        error
    end
  catch
    :nesting_too_deep -> {:error, :nesting_too_deep}
  end
end
