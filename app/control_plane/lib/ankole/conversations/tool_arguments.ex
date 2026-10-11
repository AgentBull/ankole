defmodule Ankole.Conversations.ToolArguments do
  @moduledoc "Bounds and parses model tool arguments without repairing missing string content."

  alias Ankole.JSON
  @argument_limit 256 * 1024
  @repair_limit 64 * 1024

  def parse(text) when is_binary(text) and byte_size(text) > @argument_limit,
    do: {:error, "tool arguments exceed the #{@argument_limit}-byte limit"}

  def parse(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value, :none}
      {:error, reason} -> repair(text, reason)
    end
  end

  def validate(schema, value) do
    schema =
      ExJsonSchema.Schema.resolve(
        Map.put(schema, "$schema", "http://json-schema.org/draft-07/schema#")
      )

    case ExJsonSchema.Validator.validate(schema, value) do
      :ok ->
        {:ok, value}

      {:error, errors} ->
        {:error, Enum.map_join(errors, "; ", fn {message, path} -> "#{path}: #{message}" end)}
    end
  end

  defp repair(text, reason) when byte_size(text) > @repair_limit,
    do: {:error, "tool arguments must be valid JSON: #{inspect(reason)}"}

  defp repair(text, reason) do
    trimmed = String.trim(text)

    base =
      case Regex.run(~r/\A```(?:json)?\s*\n?([\s\S]*?)\n?```\z/i, trimmed) do
        [_, content] -> String.trim(content)
        _plain -> trimmed
      end

    [
      {:code_fence, if(base != trimmed, do: base)},
      {:balanced_object, balanced_object(base)},
      {:incomplete_container, incomplete_object(base)}
    ]
    |> Enum.reject(fn {_kind, value} -> is_nil(value) or value == text end)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.find_value(fn {kind, value} ->
      case JSON.decode(value) do
        {:ok, value} -> {:ok, value, kind}
        {:error, _} -> nil
      end
    end)
    |> case do
      nil -> {:error, "tool arguments must be valid JSON: #{inspect(reason)}"}
      result -> result
    end
  end

  defp balanced_object(text) do
    case :binary.match(text, "{") do
      {offset, _} ->
        input = binary_part(text, offset, byte_size(text) - offset)

        case scan(input, [], false, false, [], :balanced) do
          {:complete, output} -> IO.iodata_to_binary(Enum.reverse(output))
          _incomplete -> nil
        end

      :nomatch ->
        nil
    end
  end

  defp incomplete_object("{" <> _ = text) do
    case scan(text, [], false, false, [], :repair) do
      {:open, stack, output} ->
        (Enum.reverse(output) ++ stack) |> IO.iodata_to_binary() |> remove_trailing_commas()

      _invalid ->
        nil
    end
  end

  defp incomplete_object(_text), do: nil

  defp scan(<<>>, stack, false, false, output, _mode), do: {:open, stack, output}
  defp scan(<<>>, _stack, _quoted, _escaped, _output, _mode), do: :invalid

  defp scan(<<char::utf8, rest::binary>>, stack, true, escaped, output, mode) do
    encoded =
      if mode == :repair and not escaped,
        do: Map.get(%{10 => "\\n", 13 => "\\r", 9 => "\\t"}, char, <<char::utf8>>),
        else: <<char::utf8>>

    cond do
      escaped -> scan(rest, stack, true, false, [encoded | output], mode)
      char == ?\\ -> scan(rest, stack, true, true, [encoded | output], mode)
      char == ?" -> scan(rest, stack, false, false, [encoded | output], mode)
      true -> scan(rest, stack, true, false, [encoded | output], mode)
    end
  end

  defp scan(<<char::utf8, rest::binary>>, stack, false, false, output, mode) do
    encoded = <<char::utf8>>

    case char do
      ?" ->
        scan(rest, stack, true, false, [encoded | output], mode)

      ?{ ->
        scan(rest, ["}" | stack], false, false, [encoded | output], mode)

      ?[ ->
        scan(rest, ["]" | stack], false, false, [encoded | output], mode)

      closing when closing in [?}, ?]] ->
        case stack do
          [^encoded | []] when mode == :balanced -> {:complete, [encoded | output]}
          [^encoded | remaining] -> scan(rest, remaining, false, false, [encoded | output], mode)
          _mismatch -> :invalid
        end

      _other ->
        scan(rest, stack, false, false, [encoded | output], mode)
    end
  end

  defp remove_trailing_commas(text),
    do: commas(text, false, false, []) |> Enum.reverse() |> IO.iodata_to_binary()

  defp commas(<<>>, _quoted, _escaped, output), do: output

  defp commas(<<char::utf8, rest::binary>>, true, escaped, output) do
    cond do
      escaped -> commas(rest, true, false, [<<char::utf8>> | output])
      char == ?\\ -> commas(rest, true, true, [<<char::utf8>> | output])
      char == ?" -> commas(rest, false, false, [<<char::utf8>> | output])
      true -> commas(rest, true, false, [<<char::utf8>> | output])
    end
  end

  defp commas(<<char::utf8, rest::binary>>, false, false, output) do
    cond do
      char == ?" ->
        commas(rest, true, false, [<<char::utf8>> | output])

      char == ?, and String.starts_with?(String.trim_leading(rest), ["}", "]"]) ->
        commas(rest, false, false, output)

      true ->
        commas(rest, false, false, [<<char::utf8>> | output])
    end
  end
end
