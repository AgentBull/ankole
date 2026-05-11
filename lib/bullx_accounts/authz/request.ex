defmodule BullXAccounts.AuthZ.Request do
  @moduledoc """
  Normalized AuthZ request shape consumed by `BullXAccounts.AuthZ`.

  All fields are caller-supplied:

    * `user_id` is a UUID string for the requesting BullX user.
    * `resource` and `action` remain strings; they are never converted to
      atoms because they may originate from external request data.
    * `context` is Cedar-context-compatible data wrapped under
      `context.request` before being passed to Cedar.
  """

  @max_int 9_223_372_036_854_775_807
  @min_int -9_223_372_036_854_775_808

  @enforce_keys [:user_id, :resource, :action, :context]
  defstruct [:user_id, :resource, :action, :context]

  @type t :: %__MODULE__{
          user_id: String.t(),
          resource: String.t(),
          action: String.t(),
          context: map()
        }

  alias BullXAccounts.User

  @doc """
  Build a normalized AuthZ request from caller arguments.
  """
  @spec build(User.t() | Ecto.UUID.t() | nil, String.t(), String.t(), term()) ::
          {:ok, t()} | {:error, :invalid_request}
  def build(user, resource, action, context) do
    with {:ok, user_id} <- normalize_user(user),
         {:ok, resource} <- normalize_string(resource),
         {:ok, action} <- normalize_action(action),
         {:ok, context} <- normalize_context(context) do
      {:ok, %__MODULE__{user_id: user_id, resource: resource, action: action, context: context}}
    end
  end

  @doc """
  Split a permission key into `{resource, action}` at the final `:`.
  """
  @spec split_permission_key(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_request}
  def split_permission_key(permission) when is_binary(permission) do
    case String.split(permission, ":") do
      [_single] ->
        {:error, :invalid_request}

      parts when length(parts) >= 2 ->
        {action, resource_parts} = List.pop_at(parts, length(parts) - 1)
        resource = Enum.join(resource_parts, ":")

        cond do
          resource == "" -> {:error, :invalid_request}
          action == "" -> {:error, :invalid_request}
          true -> {:ok, resource, action}
        end
    end
  end

  def split_permission_key(_permission), do: {:error, :invalid_request}

  @doc """
  Compute a canonical decision-cache key for a normalized request.

  The hash uses recursively sorted string keys so logically equal contexts
  produce the same key. List order remains part of the hash.
  """
  @spec cache_key(t()) :: {String.t(), String.t(), String.t(), String.t()}
  def cache_key(%__MODULE__{} = request) do
    canonical_context = canonicalize(request.context)
    context_hash = BullX.Ext.generic_hash(:erlang.term_to_binary(canonical_context))

    {request.user_id, request.resource, request.action, context_hash}
  end

  defp normalize_user(%User{id: id}), do: normalize_user(id)

  defp normalize_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_user(_other), do: {:error, :invalid_request}

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_string(_other), do: {:error, :invalid_request}

  defp normalize_action(value) do
    with {:ok, action} <- normalize_string(value) do
      if String.contains?(action, ":") do
        {:error, :invalid_request}
      else
        {:ok, action}
      end
    end
  end

  defp normalize_context(context) when is_map(context) do
    case normalize_value(context) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_request}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_context(_other), do: {:error, :invalid_request}

  defp normalize_value(nil), do: :error
  defp normalize_value(value) when is_boolean(value), do: {:ok, value}
  defp normalize_value(value) when is_binary(value), do: {:ok, value}

  defp normalize_value(value) when is_integer(value) do
    if value >= @min_int and value <= @max_int do
      {:ok, value}
    else
      :error
    end
  end

  defp normalize_value(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn element, {:ok, acc} ->
      case normalize_value(element) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp normalize_value(%_struct{} = _value), do: :error

  defp normalize_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key),
           {:ok, value} <- normalize_value(val) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_value(_other), do: :error

  defp normalize_key(key) when is_binary(key), do: {:ok, key}

  defp normalize_key(key) when is_atom(key) and not is_boolean(key) and key != nil,
    do: {:ok, Atom.to_string(key)}

  defp normalize_key(_other), do: :error

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other
end
