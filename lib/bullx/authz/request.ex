defmodule BullX.AuthZ.Request do
  @moduledoc """
  Normalized authorization request consumed by `BullX.AuthZ`.

  Resource, action, and context values remain strings and JSON-compatible data;
  AuthZ never converts caller-provided permission data to atoms.
  """

  alias BullX.RuleEngine.JSON
  alias BullX.Principals.Principal

  @resource_glob_metacharacters ~r/[\*\?\[\]\{\}]/

  @enforce_keys [:principal_uid, :resource, :action, :context]
  defstruct [:principal_uid, :resource, :action, :context, :principal]

  @type t :: %__MODULE__{
          principal_uid: String.t(),
          resource: String.t(),
          action: String.t(),
          context: map(),
          principal: Principal.t() | nil
        }

  @spec build(Principal.t() | String.t() | nil, String.t(), String.t(), term()) ::
          {:ok, t()} | {:error, :invalid_request}
  def build(principal, resource, action, context) do
    with {:ok, principal_uid} <- normalize_principal(principal),
         {:ok, resource} <- normalize_resource(resource),
         {:ok, action} <- normalize_action(action),
         {:ok, context} <- normalize_context(context) do
      {:ok,
       %__MODULE__{
         principal_uid: principal_uid,
         resource: resource,
         action: action,
         context: context
       }}
    end
  end

  @spec with_principal(t(), Principal.t()) :: t()
  def with_principal(%__MODULE__{} = request, %Principal{} = principal) do
    %__MODULE__{request | principal_uid: principal.uid, principal: principal}
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
    with {:ok, resource} <- normalize_resource(resource),
         {:ok, action} <- normalize_action(action) do
      {:ok, resource, action}
    end
  end

  defp normalize_principal(%Principal{uid: uid}), do: normalize_principal(uid)

  defp normalize_principal(uid) when is_binary(uid) do
    case String.trim(uid) do
      "" -> {:error, :invalid_request}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_principal(_principal), do: {:error, :invalid_request}

  defp normalize_resource(value) do
    with {:ok, resource} <- normalize_string(value) do
      case Regex.match?(@resource_glob_metacharacters, resource) do
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
    context
    |> JSON.normalize_map()
    |> case do
      {:ok, context} -> {:ok, context}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_context(_context), do: {:error, :invalid_request}
end
