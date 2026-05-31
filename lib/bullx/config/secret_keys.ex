defmodule BullX.Config.SecretKeys do
  @moduledoc """
  Discovers which database-backed config keys must be encrypted at rest.

  Config modules declare secret keys through the `BullX.Config` macro. This
  module builds a cached allowlist from in-tree config modules and plugin config
  modules so writers can encrypt before persisting to `app_configs`.
  """

  @bullx_prefix "Elixir.BullX.Config."

  @doc """
  Returns `true` if the given DB key was declared with `secret: true` in any
  `use BullX.Config` module.
  """
  @spec secret?(String.t()) :: boolean()
  def secret?(key) when is_binary(key) do
    MapSet.member?(keys(), key)
  end

  @doc "Clears the cached key set. Used in tests to force a fresh build."
  def reset do
    :persistent_term.erase({__MODULE__, :keys})
    :ok
  end

  defp keys do
    case :persistent_term.get({__MODULE__, :keys}, :unset) do
      :unset ->
        built = build()
        :persistent_term.put({__MODULE__, :keys}, built)
        built

      existing ->
        existing
    end
  end

  defp build do
    plugin_modules = plugin_config_modules()

    configured_modules()
    |> MapSet.union(plugin_modules)
    |> Enum.flat_map(&secret_keys_for(&1, plugin_modules))
    |> MapSet.new()
  end

  defp configured_modules do
    :code.all_loaded()
    |> Enum.map(fn {mod, _} -> mod end)
    |> MapSet.new()
    |> MapSet.union(application_modules())
  end

  defp application_modules do
    case :application.get_key(:bullx, :modules) do
      {:ok, modules} -> MapSet.new(modules)
      _other -> MapSet.new()
    end
  end

  defp plugin_config_modules do
    BullX.Plugins.Discovery.config_modules()
    |> MapSet.new()
  end

  defp secret_keys_for(mod, plugin_modules) when is_atom(mod) do
    with true <- allowed_module?(mod, plugin_modules),
         {:module, ^mod} <- Code.ensure_loaded(mod),
         true <- function_exported?(mod, :__bullx_secret_keys__, 0) do
      mod.__bullx_secret_keys__()
    else
      _other -> []
    end
  end

  defp allowed_module?(mod, plugin_modules) when is_atom(mod) do
    mod_str = Atom.to_string(mod)

    String.starts_with?(mod_str, @bullx_prefix) or
      MapSet.member?(plugin_modules, mod)
  end
end
