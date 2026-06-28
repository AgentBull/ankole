defmodule Ankole.AuthZ.Input do
  @moduledoc false

  @resource_glob_metacharacters ~r/[\*\?\[\]\{\}]/
  @max_json_integer 9_223_372_036_854_775_807
  @min_json_integer -9_223_372_036_854_775_808

  @group_fields [:name, :display_name, :kind, :computed_condition, :description, :metadata]
  @binding_fields [:provider, :external_id, :group_id, :metadata]
  @grant_fields [
    :principal_uid,
    :group_id,
    :resource_pattern,
    :action,
    :condition,
    :description,
    :metadata
  ]

  def group_create_attrs(attrs) when is_map(attrs) do
    attrs
    |> take_attrs(@group_fields)
    |> Map.put(:built_in, false)
  end

  def group_update_attrs(%{built_in: true}, attrs) when is_map(attrs) do
    attrs
    |> drop_attrs([:name, :kind, :built_in, :computed_condition])
    |> take_attrs(@group_fields)
  end

  def group_update_attrs(%{built_in: false}, attrs) when is_map(attrs) do
    take_attrs(attrs, @group_fields)
  end

  def binding_attrs(attrs) when is_map(attrs) do
    take_attrs(attrs, [:group_name | @binding_fields])
  end

  def grant_attrs(attrs) when is_map(attrs) do
    take_attrs(attrs, [:group_name | @grant_fields])
  end

  def normalize_actions(actions) when is_list(actions) do
    normalized =
      Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
        case normalize_required_text(action) do
          {:ok, action} ->
            case String.contains?(action, ":") do
              true -> {:halt, {:error, :invalid_request}}
              false -> {:cont, {:ok, [action | acc]}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case normalized do
      {:ok, []} -> {:error, :invalid_request}
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_actions(_actions), do: {:error, :invalid_request}

  def normalize_resource(resource) do
    with {:ok, resource} <- normalize_required_text(resource) do
      case Regex.match?(@resource_glob_metacharacters, resource) do
        true -> {:error, :invalid_request}
        false -> {:ok, resource}
      end
    end
  end

  def normalize_context(context) when is_map(context) do
    case normalize_json_value(context) do
      {:ok, %{} = normalized} -> {:ok, normalized}
      {:ok, _value} -> {:error, :invalid_request}
      :error -> {:error, :invalid_request}
    end
  end

  def normalize_context(_context), do: {:error, :invalid_request}

  def normalize_provider(value) do
    with {:ok, text} <- normalize_required_text(value) do
      provider = String.downcase(text)

      case Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, provider) do
        true -> {:ok, provider}
        false -> {:error, :invalid_provider}
      end
    end
  end

  def normalize_required_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request}
      trimmed -> {:ok, trimmed}
    end
  end

  def normalize_required_text(_value), do: {:error, :invalid_request}

  def split_permission_key(permission) when is_binary(permission) do
    case String.split(permission, ":") do
      [_single] ->
        {:error, :invalid_request}

      parts when length(parts) >= 2 ->
        {action, resource_parts} = List.pop_at(parts, length(parts) - 1)
        resource = Enum.join(resource_parts, ":")

        with {:ok, resource} <- normalize_resource(resource),
             {:ok, [action]} <- normalize_actions([action]) do
          {:ok, resource, action}
        end
    end
  end

  def split_permission_key(_permission), do: {:error, :invalid_request}

  def take_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  def drop_attrs(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.delete(Atom.to_string(key))
    end)
  end

  def fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp normalize_json_value(nil), do: {:ok, nil}
  defp normalize_json_value(value) when is_boolean(value), do: {:ok, value}
  defp normalize_json_value(value) when is_binary(value), do: {:ok, value}
  defp normalize_json_value(value) when is_float(value), do: {:ok, value}

  defp normalize_json_value(value)
       when is_integer(value) and value >= @min_json_integer and value <= @max_json_integer,
       do: {:ok, value}

  defp normalize_json_value(value) when is_integer(value), do: :error

  defp normalize_json_value(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_json_value(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_json_value(%_struct{}), do: :error

  defp normalize_json_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, key} <- normalize_json_key(key),
           {:ok, val} <- normalize_json_value(val) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_json_value(_value), do: :error

  defp normalize_json_key(key) when is_binary(key), do: {:ok, key}

  defp normalize_json_key(key) when is_atom(key) and not is_boolean(key) and key != nil do
    {:ok, Atom.to_string(key)}
  end

  defp normalize_json_key(_key), do: :error
end
