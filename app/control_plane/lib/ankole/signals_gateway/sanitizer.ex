defmodule Ankole.SignalsGateway.Sanitizer do
  @moduledoc """
  Bounded redaction for error details and log previews.

  This module is deliberately not a durable payload normalizer. Mailbox,
  outbox, and provider mirror payloads must pass `JsonPayload` instead of being
  repaired here.
  """

  @default_max_depth 6
  @default_max_items 50
  @default_max_string 1_000
  @redacted "[REDACTED]"

  @sensitive_keys MapSet.new([
                    "access_token",
                    "api_key",
                    "auth",
                    "authorization",
                    "client_secret",
                    "cookie",
                    "password",
                    "private_key",
                    "refresh_token",
                    "secret",
                    "set_cookie",
                    "signature",
                    "token"
                  ])

  @doc """
  Returns a JSON-shaped, redacted, bounded term for error details.
  """
  @spec transport(term(), keyword()) :: term()
  def transport(value, opts \\ []) do
    limits = limits(opts)
    sanitize(value, limits, 0)
  end

  @doc """
  Returns a compact string preview of a sanitized value.
  """
  @spec preview(term(), keyword()) :: String.t()
  def preview(value, opts \\ []) do
    value
    |> transport(opts)
    |> bounded_inspect(max_string(opts))
  end

  defp sanitize(_value, limits, depth) when depth >= limits.max_depth do
    %{"__truncated__" => "max_depth"}
  end

  defp sanitize(%DateTime{} = value, _limits, _depth), do: DateTime.to_iso8601(value)
  defp sanitize(%NaiveDateTime{} = value, _limits, _depth), do: NaiveDateTime.to_iso8601(value)
  defp sanitize(%Date{} = value, _limits, _depth), do: Date.to_iso8601(value)
  defp sanitize(%Time{} = value, _limits, _depth), do: Time.to_iso8601(value)

  defp sanitize(%_struct{} = value, limits, depth) do
    %{
      "__type__" => "struct",
      "module" => value.__struct__ |> Atom.to_string() |> truncate(limits.max_string)
    }
    |> sanitize(limits, depth + 1)
  end

  defp sanitize(value, limits, depth) when is_map(value) do
    value
    |> Enum.take(limits.max_items)
    |> Enum.map(fn {key, map_value} ->
      string_key = key_to_string(key, limits)

      case sensitive_key?(string_key) do
        true -> {string_key, @redacted}
        false -> {string_key, sanitize(map_value, limits, depth + 1)}
      end
    end)
    |> Map.new()
    |> maybe_mark_truncated(map_size(value), limits.max_items)
  end

  defp sanitize(value, limits, depth) when is_list(value) do
    value
    |> Enum.take(limits.max_items)
    |> Enum.map(&sanitize(&1, limits, depth + 1))
    |> maybe_append_truncated(length(value), limits.max_items)
  end

  defp sanitize(value, limits, _depth) when is_binary(value),
    do: truncate(value, limits.max_string)

  defp sanitize(value, _limits, _depth)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize(value, limits, _depth) when is_atom(value) do
    value
    |> Atom.to_string()
    |> truncate(limits.max_string)
  end

  defp sanitize(value, limits, _depth) when is_pid(value),
    do: runtime_preview("pid", value, limits)

  defp sanitize(value, limits, _depth) when is_function(value),
    do: runtime_preview("function", value, limits)

  defp sanitize(value, limits, _depth) when is_reference(value),
    do: runtime_preview("reference", value, limits)

  defp sanitize(value, limits, _depth) when is_port(value),
    do: runtime_preview("port", value, limits)

  defp sanitize(value, limits, depth) when is_tuple(value) do
    %{
      "__type__" => "tuple",
      "items" =>
        value
        |> Tuple.to_list()
        |> Enum.take(limits.max_items)
        |> Enum.map(&sanitize(&1, limits, depth + 1))
    }
  end

  defp sanitize(value, limits, _depth), do: runtime_preview("term", value, limits)

  defp runtime_preview(type, value, limits) do
    %{"__type__" => type, "value" => bounded_inspect(value, limits.max_string)}
  end

  defp key_to_string(key, limits) when is_binary(key), do: truncate(key, limits.max_string)

  defp key_to_string(key, limits) when is_atom(key),
    do: key |> Atom.to_string() |> truncate(limits.max_string)

  defp key_to_string(key, limits), do: bounded_inspect(key, limits.max_string)

  defp sensitive_key?(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace("-", "_")
      |> String.replace(".", "_")

    MapSet.member?(@sensitive_keys, normalized) ||
      String.ends_with?(normalized, "_token") ||
      String.ends_with?(normalized, "_secret") ||
      String.ends_with?(normalized, "_password") ||
      String.ends_with?(normalized, "_authorization") ||
      String.ends_with?(normalized, "_cookie") ||
      String.ends_with?(normalized, "_signature")
  end

  defp maybe_mark_truncated(map, original_size, max_items) when original_size > max_items,
    do: Map.put(map, "__truncated__", original_size - max_items)

  defp maybe_mark_truncated(map, _original_size, _max_items), do: map

  defp maybe_append_truncated(list, original_size, max_items) when original_size > max_items,
    do: list ++ [%{"__truncated__" => original_size - max_items}]

  defp maybe_append_truncated(list, _original_size, _max_items), do: list

  defp bounded_inspect(value, max_string) do
    value
    |> inspect(limit: 10, printable_limit: max_string)
    |> truncate(max_string)
  end

  defp truncate(value, max_string) when is_binary(value) do
    case String.length(value) > max_string do
      true -> String.slice(value, 0, max_string) <> "...[truncated]"
      false -> value
    end
  end

  defp limits(opts) do
    %{
      max_depth: max(1, Keyword.get(opts, :max_depth, @default_max_depth)),
      max_items: max(1, Keyword.get(opts, :max_items, @default_max_items)),
      max_string: max_string(opts)
    }
  end

  defp max_string(opts), do: max(16, Keyword.get(opts, :max_string, @default_max_string))
end
