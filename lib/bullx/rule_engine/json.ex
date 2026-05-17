defmodule BullX.RuleEngine.JSON do
  @moduledoc """
  JSON-compatible data normalization for rule-engine inputs.

  Rule-engine surfaces pass explicit facts into Rust/CEL as JSON-compatible
  maps. Atom keys are stringified for Elixir ergonomics, but atom values and
  other BEAM-specific terms are rejected before the NIF boundary.
  """

  @max_int 9_223_372_036_854_775_807
  @min_int -9_223_372_036_854_775_808

  @type json_scalar :: nil | boolean() | String.t() | integer() | float()
  @type json_value :: json_scalar() | [json_value()] | %{String.t() => json_value()}

  @spec normalize_map(term()) :: {:ok, %{String.t() => json_value()}} | :error
  def normalize_map(value) when is_map(value) do
    case normalize_value(value) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> :error
      :error -> :error
    end
  end

  def normalize_map(_value), do: :error

  @spec normalize_value(term()) :: {:ok, json_value()} | :error
  def normalize_value(nil), do: {:ok, nil}
  def normalize_value(value) when is_boolean(value), do: {:ok, value}
  def normalize_value(value) when is_binary(value), do: {:ok, value}
  def normalize_value(value) when is_float(value), do: {:ok, value}

  def normalize_value(value) when is_integer(value) do
    case value >= @min_int and value <= @max_int do
      true -> {:ok, value}
      false -> :error
    end
  end

  def normalize_value(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case normalize_value(element) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  def normalize_value(%_struct{}), do: :error

  def normalize_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key),
           {:ok, normalized} <- normalize_value(val) do
        {:cont, {:ok, Map.put(acc, key, normalized)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  def normalize_value(_value), do: :error

  defp normalize_key(key) when is_binary(key), do: {:ok, key}

  defp normalize_key(key) when is_atom(key) and not is_boolean(key) and key != nil,
    do: {:ok, Atom.to_string(key)}

  defp normalize_key(_key), do: :error
end
