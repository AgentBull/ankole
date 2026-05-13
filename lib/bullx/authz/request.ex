defmodule BullX.AuthZ.Request do
  @moduledoc """
  Normalized authorization request consumed by `BullX.AuthZ`.

  Resource, action, and context values remain strings and JSON-like data; AuthZ
  never converts caller-provided permission data to atoms.
  """

  alias BullX.Principals.Principal

  @max_int 9_223_372_036_854_775_807
  @min_int -9_223_372_036_854_775_808

  @enforce_keys [:principal_id, :resource, :action, :context]
  defstruct [:principal_id, :resource, :action, :context, :principal]

  @type t :: %__MODULE__{
          principal_id: Ecto.UUID.t(),
          resource: String.t(),
          action: String.t(),
          context: map(),
          principal: Principal.t() | nil
        }

  @spec build(Principal.t() | Ecto.UUID.t() | nil, String.t(), String.t(), term()) ::
          {:ok, t()} | {:error, :invalid_request}
  def build(principal, resource, action, context) do
    with {:ok, principal_id} <- normalize_principal(principal),
         {:ok, resource} <- normalize_resource(resource),
         {:ok, action} <- normalize_action(action),
         {:ok, context} <- normalize_context(context) do
      {:ok,
       %__MODULE__{
         principal_id: principal_id,
         resource: resource,
         action: action,
         context: context
       }}
    end
  end

  @spec with_principal(t(), Principal.t()) :: t()
  def with_principal(%__MODULE__{} = request, %Principal{} = principal) do
    %__MODULE__{request | principal_id: principal.id, principal: principal}
  end

  @spec split_permission_key(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_request}
  def split_permission_key(permission) when is_binary(permission) do
    case String.split(permission, ":") do
      [_single] ->
        {:error, :invalid_request}

      parts when length(parts) >= 2 ->
        {action, resource_parts} = List.pop_at(parts, length(parts) - 1)
        resource = Enum.join(resource_parts, ":")

        validate_permission_parts(resource, action)
    end
  end

  def split_permission_key(_permission), do: {:error, :invalid_request}

  defp validate_permission_parts("", _action), do: {:error, :invalid_request}
  defp validate_permission_parts(_resource, ""), do: {:error, :invalid_request}

  defp validate_permission_parts(resource, action) do
    {:ok, resource, action}
  end

  defp normalize_principal(%Principal{id: id}), do: normalize_principal(id)

  defp normalize_principal(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_principal(_principal), do: {:error, :invalid_request}

  defp normalize_resource(value) do
    with {:ok, resource} <- normalize_string(value) do
      case String.contains?(resource, "*") do
        true -> {:error, :invalid_request}
        false -> {:ok, resource}
      end
    end
  end

  defp normalize_action(value) do
    with {:ok, action} <- normalize_string(value) do
      case String.contains?(action, ":") do
        true -> {:error, :invalid_request}
        false -> {:ok, action}
      end
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_string(_value), do: {:error, :invalid_request}

  defp normalize_context(context) when is_map(context) do
    case normalize_value(context) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_request}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_context(_context), do: {:error, :invalid_request}

  defp normalize_value(nil), do: :error
  defp normalize_value(value) when is_boolean(value), do: {:ok, value}
  defp normalize_value(value) when is_binary(value), do: {:ok, value}

  defp normalize_value(value) when is_integer(value) do
    case value >= @min_int and value <= @max_int do
      true -> {:ok, value}
      false -> :error
    end
  end

  defp normalize_value(value) when is_list(value) do
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

  defp normalize_value(%_struct{}), do: :error

  defp normalize_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key),
           {:ok, normalized} <- normalize_value(val) do
        {:cont, {:ok, Map.put(acc, key, normalized)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_value(_value), do: :error

  defp normalize_key(key) when is_binary(key), do: {:ok, key}

  defp normalize_key(key) when is_atom(key) and not is_boolean(key) and key != nil,
    do: {:ok, Atom.to_string(key)}

  defp normalize_key(_key), do: :error
end
