defmodule Ankole.Plugins.Config do
  @moduledoc """
  AppConfigure storage for the global plugin enable list.

  Plugins are installation-global and fail closed after first-run setup, so the
  operator explicitly opts plugins in through a durable list of enabled plugin
  ids. It lives in AppConfigure (PostgreSQL) rather than process state because
  the registry reads it once at startup. During setup, all compiled plugins stay
  active and this list records the first post-setup startup policy. This is
  deliberate: activating or deactivating a plugin can add or remove supervised
  children and config keys, which is a boot-time concern, not a hot-swap.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Plugins.Spec

  @enabled_ids_key "plugins.enabled_ids"

  @doc """
  Returns the AppConfigure definition for globally enabled plugin ids.
  """
  @spec enabled_ids_definition() :: Definition.t()
  def enabled_ids_definition do
    AppConfigure.define(
      key: @enabled_ids_key,
      encrypted: false,
      schema: enabled_ids_schema(),
      scope: :global,
      default_value: [],
      description: "Plugin ids enabled on the next post-setup Ankole process start."
    )
  end

  @doc """
  Registers plugin subsystem AppConfigure keys.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([enabled_ids_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @enabled_ids_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the global enabled plugin id list.
  """
  @spec enabled_ids() :: {:ok, [String.t()]} | {:error, term()}
  def enabled_ids do
    with :ok <- ensure_registered(),
         {:ok, enabled_ids} <- AppConfigure.get(enabled_ids_definition()) do
      {:ok, enabled_ids}
    end
  end

  @doc """
  Persists the next-start enabled plugin id list.
  """
  @spec put_enabled_ids([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def put_enabled_ids(enabled_ids) do
    with :ok <- ensure_registered() do
      AppConfigure.put_global(enabled_ids_definition(), enabled_ids)
    end
  end

  @doc """
  Persists one plugin's next-start enablement without replacing other plugin choices.
  """
  @spec put_configured_enabled(String.t(), boolean()) ::
          {:ok, [String.t()]} | {:error, term()}
  def put_configured_enabled(plugin_id, enabled)
      when is_binary(plugin_id) and is_boolean(enabled) do
    with :ok <- ensure_registered() do
      AppConfigure.update_global(enabled_ids_definition(), fn enabled_ids ->
        {:ok, update_enabled_ids(enabled_ids, plugin_id, enabled)}
      end)
    end
  end

  def put_configured_enabled(_plugin_id, _enabled),
    do: {:error, :invalid_plugin_configuration}

  # IDs need not correspond to a currently discovered plugin. Keeping that
  # validation at the operator-facing catalog boundary permits deliberate
  # pre-authorization without coupling AppConfigure to one release's module list.
  defp enabled_ids_schema do
    Schema.new(fn
      values when is_list(values) -> normalize_enabled_ids(values)
      _value -> {:error, :not_array}
    end)
  end

  defp normalize_enabled_ids(values) do
    values
    |> Enum.reduce_while({:ok, MapSet.new(), []}, &collect_enabled_id/2)
    |> case do
      {:ok, _seen, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_enabled_ids(enabled_ids, plugin_id, true) do
    [plugin_id | enabled_ids]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp update_enabled_ids(enabled_ids, plugin_id, false),
    do: Enum.reject(enabled_ids, &(&1 == plugin_id))

  defp collect_enabled_id(value, {:ok, seen, ids}) when is_binary(value) do
    cond do
      not Spec.valid_id?(value) ->
        {:halt, {:error, {:invalid_plugin_id, value}}}

      MapSet.member?(seen, value) ->
        {:halt, {:error, {:duplicate_plugin_id, value}}}

      true ->
        {:cont, {:ok, MapSet.put(seen, value), [value | ids]}}
    end
  end

  defp collect_enabled_id(value, {:ok, _seen, _ids}) do
    {:halt, {:error, {:invalid_plugin_id, value}}}
  end
end
