defmodule BullX.Plugins.Discovery do
  @moduledoc false

  alias BullX.Plugins.Spec

  @spec discover() :: {:ok, [Spec.t()]} | {:error, term()}
  def discover do
    discover_apps(plugin_apps())
  end

  @spec discover!() :: [Spec.t()]
  def discover! do
    case discover() do
      {:ok, specs} ->
        specs

      {:error, reason} ->
        raise ArgumentError, "invalid BullX plugin configuration: #{inspect(reason)}"
    end
  end

  @spec config_modules() :: [module()]
  def config_modules do
    discover!()
    |> Enum.flat_map(& &1.config_modules)
  end

  @spec discover_apps([atom()]) :: {:ok, [Spec.t()]} | {:error, term()}
  def discover_apps(apps) when is_list(apps) do
    apps
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn app, {:ok, acc} ->
      case discover_app(app) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec discover_app(atom(), keyword()) :: {:ok, Spec.t()} | {:error, term()}
  def discover_app(app, opts \\ []) when is_atom(app) do
    with {:ok, modules} <- modules_for(app, opts),
         {:ok, module} <- plugin_module(app, modules) do
      Spec.build(app, module)
    end
  end

  @spec plugin_apps() :: [atom()]
  def plugin_apps do
    Application.get_env(:bullx, :plugin_apps, [])
  end

  defp modules_for(app, opts) do
    case Keyword.fetch(opts, :modules) do
      {:ok, modules} -> {:ok, modules}
      :error -> plugin_modules_from_bullx_app(app)
    end
  end

  defp plugin_modules_from_bullx_app(app) do
    with {:ok, modules} <- application_modules(:bullx) do
      modules
      |> Enum.filter(&plugin_module?/1)
      |> Enum.filter(&plugin_id_matches?(&1, Atom.to_string(app)))
      |> case do
        [] -> {:error, {:plugin_entry_not_found, app}}
        matching -> {:ok, matching}
      end
    end
  end

  defp application_modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> {:ok, modules}
      :undefined -> {:error, {:plugin_app_modules_unavailable, app}}
    end
  end

  defp plugin_module(app, modules) do
    modules
    |> Enum.filter(&plugin_module?/1)
    |> plugin_module_result(app)
  end

  defp plugin_module?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, :__bullx_plugin__, 0)
      {:error, _reason} -> false
    end
  end

  defp plugin_id_matches?(module, id) do
    case module.__bullx_plugin__() do
      %{id: ^id} -> true
      metadata when is_list(metadata) -> Keyword.get(metadata, :id) == id
      _metadata -> false
    end
  end

  defp plugin_module_result([], app), do: {:error, {:plugin_entry_not_found, app}}
  defp plugin_module_result([module], _app), do: {:ok, module}

  defp plugin_module_result(modules, app),
    do: {:error, {:multiple_plugin_entries, app, Enum.sort(modules)}}
end
