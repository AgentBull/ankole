defmodule Ankole.Plugins.Config do
  @moduledoc """
  AppConfigure storage for the global plugin disable list.

  Plugins are installation-global and default-on, so the only operator knob is a
  durable list of disabled plugin ids. It lives in AppConfigure (Postgres) rather
  than in process state because the registry reads it once at startup; a change
  therefore takes effect on the next Ankole process start, not immediately. This
  is deliberate — activating/deactivating a plugin can add or remove supervised
  children and config keys, which is a boot-time concern, not a hot-swap.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.Spec

  @disabled_ids_key "plugins.disabled_ids"

  @doc """
  Returns the AppConfigure definition for globally disabled plugin ids.
  """
  @spec disabled_ids_definition() :: Definition.t()
  def disabled_ids_definition do
    AppConfigure.define(
      key: @disabled_ids_key,
      encrypted: false,
      schema: disabled_ids_schema(),
      default_value: [],
      description: "Plugin ids disabled on the next Ankole process start."
    )
  end

  @doc """
  Registers plugin subsystem AppConfigure keys.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([disabled_ids_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @disabled_ids_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the global disabled plugin id list.
  """
  @spec disabled_ids() :: {:ok, [String.t()]} | {:error, term()}
  def disabled_ids do
    with :ok <- ensure_registered(),
         {:ok, disabled_ids} <- AppConfigure.get(disabled_ids_definition()) do
      {:ok, disabled_ids}
    end
  end

  @doc """
  Persists the next-start disabled plugin id list.
  """
  @spec put_disabled_ids([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def put_disabled_ids(disabled_ids) do
    with :ok <- ensure_registered() do
      AppConfigure.put_global(disabled_ids_definition(), disabled_ids)
    end
  end

  # Validate at write time so a malformed disable list is rejected when an
  # operator sets it, not silently mishandled at boot. The value must be an array
  # of well-formed, unique plugin ids; ids need not correspond to a plugin that
  # currently exists, so disabling an id ahead of installing its plugin is fine.
  defp disabled_ids_schema do
    Schema.new(fn
      values when is_list(values) -> normalize_disabled_ids(values)
      _value -> {:error, :not_array}
    end)
  end

  defp normalize_disabled_ids(values) do
    values
    |> Enum.reduce_while({:ok, MapSet.new(), []}, &collect_disabled_id/2)
    |> case do
      {:ok, _seen, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_disabled_id(value, {:ok, seen, ids}) when is_binary(value) do
    cond do
      not Spec.valid_id?(value) ->
        {:halt, {:error, {:invalid_plugin_id, value}}}

      MapSet.member?(seen, value) ->
        {:halt, {:error, {:duplicate_plugin_id, value}}}

      true ->
        {:cont, {:ok, MapSet.put(seen, value), [value | ids]}}
    end
  end

  defp collect_disabled_id(value, {:ok, _seen, _ids}) do
    {:halt, {:error, {:invalid_plugin_id, value}}}
  end
end
