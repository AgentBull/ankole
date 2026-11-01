defmodule Ankole.AuthZ.Input do
  @moduledoc false

  @resource_glob_metacharacters ~r/[\*\?\[\]\{\}]/
  @max_json_integer 9_223_372_036_854_775_807
  @min_json_integer -9_223_372_036_854_775_808

  @group_fields [
    :name,
    :display_name,
    :domain,
    :kind,
    :computed_condition,
    :description,
    :metadata
  ]
  @binding_fields [:provider, :external_kind, :external_id, :group_id, :metadata]
  @grant_fields [
    :principal_uid,
    :group_id,
    :source_node_id,
    :source_action,
    :target_node_id,
    :target_scope,
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

  def normalize_checks(checks) when is_list(checks) and checks != [] do
    checks
    |> Enum.map(&normalize_check/1)
    |> Ankole.Attrs.collect_results()
  end

  def normalize_checks(_checks), do: {:error, :invalid_request}

  defp normalize_check(%{resource: resource, action: action} = check) do
    with {:ok, resource} <- normalize_resource(resource),
         {:ok, [action]} <- normalize_actions([action]) do
      normalized = %{"resource" => resource, "action" => action}

      case Map.fetch(check, :grant_ids) do
        :error ->
          {:ok, normalized}

        {:ok, ids} when is_list(ids) ->
          if Enum.all?(ids, &is_binary/1),
            do: {:ok, Map.put(normalized, "grantIDs", ids)},
            else: {:error, :invalid_request}

        _invalid ->
          {:error, :invalid_request}
      end
    end
  end

  defp normalize_check(_check), do: {:error, :invalid_request}

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

  def normalize_required_text(value), do: Ankole.Attrs.required_text(value, :invalid_request)

  def validate_condition_syntax(condition) when is_binary(condition) do
    try do
      case Ankole.Kernel.authz_validate_condition(condition) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
        _other -> {:error, "is invalid"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      _kind, reason -> {:error, inspect(reason)}
    end
  end

  def validate_condition_syntax(_condition), do: {:error, "must be a string"}

  def validate_drive_condition_source(condition) when is_binary(condition) do
    case Ankole.Kernel.authz_validate_drive_condition(condition) do
      true -> :ok
      {:error, reason} -> {:error, to_string(reason)}
      _ -> {:error, "is not a valid Pod condition"}
    end
  end

  def validate_drive_condition_source(_condition), do: {:error, "must be a string"}

  def validate_resource_pattern_syntax("**"), do: {:error, "requires an explicit namespace"}

  def validate_resource_pattern_syntax(pattern) when is_binary(pattern) do
    try do
      case Ankole.Kernel.authz_validate_resource_pattern(pattern) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
        _other -> {:error, "is invalid"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      _kind, reason -> {:error, inspect(reason)}
    end
  end

  def validate_resource_pattern_syntax(_pattern), do: {:error, "must be a string"}

  defp take_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp drop_attrs(attrs, keys) do
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
