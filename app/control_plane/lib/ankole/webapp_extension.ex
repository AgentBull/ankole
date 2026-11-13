defmodule Ankole.WebappExtension do
  @moduledoc """
  Contract for dynamic modules that expand build-time TypeScript artifacts into
  the browser applications.

  A module declares `use Ankole.WebappExtension, id: "my_module"` and implements
  `generated_files/1` (plus optional `validate!/0`). `discover/0` collects all
  registered extension modules from `:ankole` application modules, configured
  plugins, and `:webapp_extension_modules` application configuration. When no
  extension modules exist, discovery and generation return an empty list.
  """

  alias Ankole.Plugins.Spec

  @type context :: %{
          edition: String.t(),
          repository_root: String.t(),
          webapps_root: String.t(),
          internals_root: String.t()
        }

  @type generated_file :: %{
          required(:path) => String.t(),
          required(:content) => String.t()
        }

  @callback extension_id() :: String.t()
  @callback validate!() :: :ok
  @callback generated_files(context()) :: [generated_file()]

  @optional_callbacks validate!: 0

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)

    quote bind_quoted: [id: id] do
      @behaviour Ankole.WebappExtension

      Module.register_attribute(__MODULE__, :ankole_webapp_extension, persist: true)
      @ankole_webapp_extension true

      @impl Ankole.WebappExtension
      def extension_id, do: unquote(id)

      @impl Ankole.WebappExtension
      def validate!, do: :ok

      defoverridable validate!: 0
    end
  end

  @doc """
  Discovers and validates all loaded or configured `Ankole.WebappExtension` modules.
  """
  @spec discover([module()] | nil) :: {:ok, [module()]} | {:error, term()}
  def discover(explicit_modules \\ nil) do
    candidates =
      case explicit_modules do
        list when is_list(list) -> list
        nil -> default_candidates()
      end

    with {:ok, entries} <- validate_candidates(Enum.uniq(candidates)),
         :ok <- ensure_unique_ids(entries) do
      sorted =
        entries
        |> Enum.sort_by(fn {id, mod} -> {id, Atom.to_string(mod)} end)
        |> Enum.map(fn {_id, mod} -> mod end)

      {:ok, sorted}
    end
  end

  @doc """
  Collects and validates generated files from all discovered `Ankole.WebappExtension` modules.
  """
  @spec generate_all(context(), [module()] | nil) ::
          {:ok,
           [%{extension_id: String.t(), module: module(), path: String.t(), content: String.t()}]}
          | {:error, term()}
  def generate_all(context, explicit_modules \\ nil) when is_map(context) do
    with {:ok, modules} <- discover(explicit_modules),
         {:ok, files} <- collect_generated_files(modules, context),
         :ok <- ensure_unique_paths(files) do
      {:ok, Enum.sort_by(files, & &1.path)}
    end
  end

  defp default_candidates do
    app_modules =
      case :application.get_key(:ankole, :modules) do
        {:ok, modules} -> Enum.filter(modules, &persisted_extension_attribute?/1)
        _ -> []
      end

    plugin_modules =
      :ankole
      |> Application.get_env(:control_plane_plugin_modules, [])
      |> Enum.flat_map(fn plugin ->
        if Code.ensure_loaded?(plugin) and function_exported?(plugin, :webapp_extensions, 0) do
          plugin.webapp_extensions()
        else
          []
        end
      end)

    configured = Application.get_env(:ankole, :webapp_extension_modules, [])
    app_modules ++ plugin_modules ++ configured
  end

  defp persisted_extension_attribute?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :__info__, 1) and
      Keyword.get(module.__info__(:attributes), :ankole_webapp_extension) == [true]
  end

  defp validate_candidates(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      case validate_module(module) do
        {:ok, id} -> {:cont, {:ok, [{id, module} | acc]}}
        {:error, reason} -> {:halt, {:error, {module, reason}}}
      end
    end)
  end

  defp validate_module(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         :ok <- require_callback(module, :extension_id, 0),
         :ok <- require_callback(module, :generated_files, 1),
         id <- module.extension_id(),
         :ok <- validate_id(id),
         :ok <- run_validate(module) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_module(_module), do: {:error, :invalid_module}

  defp require_callback(module, function, arity) do
    if function_exported?(module, function, arity) do
      :ok
    else
      {:error, {:missing_callback, function, arity}}
    end
  end

  defp validate_id(id) do
    if Spec.valid_id?(id), do: :ok, else: {:error, {:invalid_extension_id, id}}
  end

  defp run_validate(module) do
    if function_exported?(module, :validate!, 0) do
      case module.validate!() do
        :ok -> :ok
        other -> {:error, {:invalid_validation_result, other}}
      end
    else
      :ok
    end
  rescue
    error -> {:error, {:validation_failed, Exception.message(error)}}
  end

  defp ensure_unique_ids(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {id, module}, {:ok, seen} ->
      case Map.fetch(seen, id) do
        {:ok, existing} ->
          {:halt, {:error, {:duplicate_extension_id, id, existing, module}}}

        :error ->
          {:cont, {:ok, Map.put(seen, id, module)}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_generated_files(modules, context) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      id = module.extension_id()

      case normalize_generated_files(module.generated_files(context), id, module, context) do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        {:error, reason} -> {:halt, {:error, {module, reason}}}
      end
    end)
  end

  defp normalize_generated_files(files, id, module, context) when is_list(files) do
    Enum.reduce_while(files, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_file_entry(entry, id, module, context) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_generated_files(other, _id, _module, _context),
    do: {:error, {:invalid_generated_files, other}}

  defp normalize_file_entry(%{path: path, content: content}, id, module, context)
       when is_binary(path) and path != "" and is_binary(content) do
    case resolve_safe_path(path, context) do
      {:ok, resolved} ->
        {:ok,
         %{
           extension_id: id,
           module: module,
           path: resolved,
           content: ensure_trailing_newline(content)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_file_entry(entry, _id, _module, _context),
    do: {:error, {:invalid_generated_file_entry, entry}}

  defp resolve_safe_path(path, context) do
    expanded = Path.expand(path, context.repository_root)

    allowed_roots = [
      Path.expand(context.webapps_root),
      Path.expand(context.internals_root)
    ]

    if Enum.any?(allowed_roots, &String.starts_with?(expanded, &1 <> "/")) do
      {:ok, expanded}
    else
      {:error, {:unsafe_generated_path, path}}
    end
  end

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end

  defp ensure_unique_paths(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, seen} ->
      case Map.fetch(seen, file.path) do
        {:ok, existing} ->
          {:halt, {:error, {:duplicate_generated_path, file.path, existing, file.module}}}

        :error ->
          {:cont, {:ok, Map.put(seen, file.path, file.module)}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
