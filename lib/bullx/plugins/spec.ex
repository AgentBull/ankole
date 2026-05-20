defmodule BullX.Plugins.Spec do
  @moduledoc false

  alias BullX.Plugins.Extension

  @enforce_keys [:app, :id, :module, :api_version]
  defstruct [:app, :id, :module, :api_version, metadata: %{}, extensions: [], config_modules: []]

  @type t :: %__MODULE__{
          app: atom(),
          id: String.t(),
          module: module(),
          api_version: pos_integer(),
          metadata: map(),
          extensions: [Extension.t()],
          config_modules: [module()]
        }

  @type localized_text :: String.t() | %{String.t() => String.t()}

  @supported_api_version 1

  @spec build(atom(), module()) :: {:ok, t()} | {:error, term()}
  def build(app, module) when is_atom(app) and is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :__bullx_plugin__, 0),
         {:ok, metadata} <- normalize_metadata(module.__bullx_plugin__()),
         :ok <- validate_api_version(metadata.api_version),
         :ok <- validate_id(app, metadata.id),
         {:ok, extensions} <- normalize_extensions(metadata.id, call_list(module, :extensions)),
         {:ok, config_modules} <- normalize_config_modules(call_list(module, :config_modules)) do
      {:ok,
       %__MODULE__{
         app: app,
         id: metadata.id,
         module: module,
         api_version: metadata.api_version,
         metadata: metadata.raw,
         extensions: extensions,
         config_modules: config_modules
       }}
    else
      false -> {:error, {:plugin_marker_missing, module}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_metadata(metadata) when is_list(metadata) do
    metadata
    |> Map.new()
    |> normalize_metadata()
  end

  defp normalize_metadata(%{} = metadata) do
    with {:ok, id} <- fetch(metadata, :id),
         {:ok, api_version} <- fetch(metadata, :api_version),
         true <- is_binary(id),
         true <- is_integer(api_version),
         :ok <- validate_optional_localized_text(metadata, :display_name),
         :ok <- validate_optional_localized_text(metadata, :description) do
      {:ok, %{id: id, api_version: api_version, raw: metadata}}
    else
      false -> {:error, {:invalid_plugin_metadata, metadata}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_metadata(metadata), do: {:error, {:invalid_plugin_metadata, metadata}}

  defp validate_optional_localized_text(metadata, key) do
    case fetch_optional(metadata, key) do
      {:ok, nil} -> :ok
      {:ok, value} -> validate_localized_text(key, value)
    end
  end

  defp fetch_optional(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, Map.get(metadata, Atom.to_string(key))}
    end
  end

  defp validate_localized_text(_key, value) when is_binary(value), do: :ok

  defp validate_localized_text(key, value) when is_map(value) do
    case Enum.all?(value, fn {locale, text} -> is_binary(locale) and is_binary(text) end) do
      true -> :ok
      false -> {:error, {:invalid_plugin_metadata_field, key, value}}
    end
  end

  defp validate_localized_text(key, value),
    do: {:error, {:invalid_plugin_metadata_field, key, value}}

  defp fetch(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_plugin_metadata, key}}
    end
  end

  defp validate_api_version(@supported_api_version), do: :ok

  defp validate_api_version(version),
    do: {:error, {:unsupported_plugin_api_version, version, @supported_api_version}}

  defp validate_id(app, id) do
    case Atom.to_string(app) do
      ^id -> :ok
      expected -> {:error, {:plugin_id_mismatch, app, id, expected}}
    end
  end

  defp call_list(module, function) do
    case function_exported?(module, function, 0) do
      true -> apply(module, function, [])
      false -> []
    end
  end

  defp normalize_extensions(plugin_id, extensions) when is_list(extensions) do
    Enum.reduce_while(extensions, {:ok, []}, fn extension, {:ok, acc} ->
      case Extension.normalize(plugin_id, extension) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_extensions(_plugin_id, extensions),
    do: {:error, {:invalid_plugin_extensions, extensions}}

  defp normalize_config_modules(modules) when is_list(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, acc} ->
      case validate_config_module(module) do
        :ok -> {:cont, {:ok, [module | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_config_modules(modules), do: {:error, {:invalid_plugin_config_modules, modules}}

  defp validate_config_module(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :__bullx_secret_keys__, 0) do
      :ok
    else
      {:error, reason} -> {:error, {:plugin_config_module_not_loaded, module, reason}}
      false -> {:error, {:invalid_plugin_config_module, module}}
    end
  end

  defp validate_config_module(module), do: {:error, {:invalid_plugin_config_module, module}}
end
