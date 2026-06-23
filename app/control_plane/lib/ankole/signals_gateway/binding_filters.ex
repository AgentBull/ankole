defmodule Ankole.SignalsGateway.BindingFilters do
  @moduledoc """
  Deterministic v1 admission filters for signal bindings.

  v1 intentionally supports only exact equality over a small allowlist. This
  keeps the user model explicit while leaving one stable place to grow future
  rule routing.
  """

  import Kernel, except: [match?: 2]

  @allowed_fields MapSet.new([
                    "adapter",
                    "binding_name",
                    "signal_channel_id",
                    "provider_entry_id",
                    "provider_thread_id",
                    "channel_kind",
                    "reply_mode",
                    "sender_key",
                    "actor_input_type",
                    "action_id",
                    "metadata.event_type",
                    "metadata.event_kind",
                    "metadata.repository",
                    "channel_metadata.realm",
                    "channel_metadata.repository"
                  ])

  @type result :: :match | :no_match | {:error, term()}

  @doc """
  Evaluates binding filters against a constructed ingress fact.
  """
  @spec match?(map() | nil, map()) :: result()
  def match?(filters, fact)

  def match?(nil, _fact), do: :match
  def match?(filters, _fact) when filters == %{}, do: :match

  def match?(%{"eq" => eq_filters} = filters, fact) when map_size(filters) == 1 do
    match_eq(eq_filters, fact)
  end

  def match?(%{eq: eq_filters} = filters, fact) when map_size(filters) == 1 do
    match_eq(eq_filters, fact)
  end

  def match?(%{} = _filters, _fact), do: {:error, :unsupported_binding_filter}
  def match?(_filters, _fact), do: {:error, :invalid_binding_filter}

  defp match_eq(filters, fact) when is_map(filters) and map_size(filters) == 0 do
    match?(%{}, fact)
  end

  defp match_eq(filters, fact) when is_map(filters) do
    filters
    |> Enum.map(fn {field, expected} -> match_field(field, expected, fact) end)
    |> Enum.reduce_while(:match, fn
      :match, :match -> {:cont, :match}
      :no_match, :match -> {:halt, :no_match}
      {:error, _reason} = error, :match -> {:halt, error}
    end)
  end

  defp match_eq(_filters, _fact), do: {:error, :invalid_binding_filter}

  defp match_field(field, expected, fact) do
    with {:ok, field} <- normalize_field(field),
         :ok <- allowed_field?(field),
         :ok <- scalar?(expected),
         {:ok, actual} <- fetch_field(fact, field),
         :ok <- scalar?(actual) do
      compare_scalar(actual, expected)
    end
  end

  defp normalize_field(field) when is_atom(field), do: {:ok, Atom.to_string(field)}
  defp normalize_field(field) when is_binary(field), do: {:ok, field}
  defp normalize_field(_field), do: {:error, :invalid_binding_filter_field}

  defp allowed_field?(field) do
    case MapSet.member?(@allowed_fields, field) do
      true -> :ok
      false -> {:error, {:unsupported_binding_filter_field, field}}
    end
  end

  defp fetch_field(fact, "metadata." <> key), do: fetch_nested(Map.get(fact, :metadata), key)

  defp fetch_field(fact, "channel_metadata." <> key),
    do: fetch_nested(Map.get(fact, :channel_metadata), key)

  defp fetch_field(fact, field) do
    fact
    |> Map.get(String.to_existing_atom(field))
    |> normalize_actual()
  rescue
    ArgumentError -> {:error, {:unsupported_binding_filter_field, field}}
  end

  defp fetch_nested(%{} = map, key), do: map |> Map.get(key) |> normalize_actual()
  defp fetch_nested(_map, _key), do: {:ok, nil}

  defp normalize_actual(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_actual(value), do: {:ok, value}

  defp scalar?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp scalar?(_value), do: {:error, :invalid_binding_filter_value}

  defp compare_scalar(actual, expected) do
    case actual == expected do
      true -> :match
      false -> :no_match
    end
  end
end
