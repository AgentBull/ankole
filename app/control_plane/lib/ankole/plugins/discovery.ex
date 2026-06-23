defmodule Ankole.Plugins.Discovery do
  @moduledoc """
  Discovers compiled first-party plugin modules from local plugin roots.
  """

  alias Ankole.Plugins.Spec

  @repo_root Path.expand("../../../../../", __DIR__)
  @default_roots [
    Path.join(@repo_root, "plugins"),
    Path.join(@repo_root, "internals/plugins")
  ]

  @type opts :: keyword()

  @doc """
  Returns the default source roots scanned for plugin declarations.
  """
  @spec default_roots() :: [Path.t()]
  def default_roots, do: @default_roots

  @doc """
  Discovers plugin specs from source roots and explicit modules.
  """
  @spec discover(opts()) :: {:ok, [Spec.t()]} | {:error, term()}
  def discover(opts \\ []) do
    roots = Keyword.get(opts, :roots, default_roots())
    explicit_modules = Keyword.get(opts, :modules, [])

    with {:ok, root_modules} <- modules_from_roots(roots),
         {:ok, plugin_root_modules} <- plugin_modules_from_roots(root_modules),
         modules <- uniq_modules(plugin_root_modules ++ explicit_modules),
         {:ok, specs} <- specs_from_modules(modules) do
      {:ok, Enum.sort_by(specs, & &1.id)}
    end
  end

  defp modules_from_roots(roots) do
    roots
    |> Enum.flat_map(&source_files/1)
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case modules_from_file(file) do
        {:ok, modules} -> {:cont, {:ok, modules ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_files(root) do
    case File.dir?(root) do
      true -> root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()
      false -> []
    end
  end

  defp modules_from_file(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, file: file) do
      {:ok, defmodules(ast)}
    else
      {:error, {_line, error, token}} -> {:error, {:invalid_plugin_source, file, error, token}}
      {:error, reason} -> {:error, {:invalid_plugin_source, file, reason}}
    end
  end

  defp defmodules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, _body]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp uniq_modules(modules) do
    modules
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp plugin_modules_from_roots(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      case root_plugin_module?(module) do
        {:ok, true} -> {:cont, {:ok, [module | acc]}}
        {:ok, false} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root_plugin_module?(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        {:ok, Ankole.Plugins.Plugin in behaviours(module)}

      {:error, reason} ->
        {:error, {:plugin_module_not_loaded, module, reason}}
    end
  end

  defp behaviours(module) do
    module
    |> module_attributes()
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp module_attributes(module), do: module.module_info(:attributes)

  defp specs_from_modules(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, acc} ->
      case Spec.from_module(module) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, reason} -> {:error, reason}
    end
  end
end
