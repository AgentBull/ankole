defmodule BullX.Plugins.Extension do
  @moduledoc """
  Normalized declaration of one plugin-provided extension point implementation.

  Extension ids are only unique within their extension point, while `plugin_id`
  records which compile-time plugin owns the implementation. Runtime callers use
  this struct instead of reading raw plugin metadata.
  """

  @enforce_keys [:plugin_id, :point, :id, :module]
  defstruct [:plugin_id, :point, :id, :module, opts: []]

  @type t :: %__MODULE__{
          plugin_id: String.t(),
          point: atom() | String.t(),
          id: atom() | String.t(),
          module: module(),
          opts: keyword() | map()
        }

  @spec normalize(String.t(), map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def normalize(plugin_id, %__MODULE__{} = extension) when is_binary(plugin_id) do
    {:ok, %{extension | plugin_id: plugin_id}}
  end

  def normalize(plugin_id, declaration) when is_binary(plugin_id) do
    data = to_map(declaration)

    with {:ok, point} <- fetch(data, :point),
         {:ok, id} <- fetch(data, :id),
         {:ok, module} <- fetch(data, :module),
         :ok <- validate_identifier(:point, point),
         :ok <- validate_identifier(:id, id),
         :ok <- validate_module(module) do
      {:ok,
       %__MODULE__{
         plugin_id: plugin_id,
         point: point,
         id: id,
         module: module,
         opts: Map.get(data, :opts, [])
       }}
    end
  end

  defp to_map(%{} = declaration), do: declaration
  defp to_map(declaration) when is_list(declaration), do: Map.new(declaration)
  defp to_map(_declaration), do: %{}

  defp fetch(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_extension_field, key}}
    end
  end

  defp validate_identifier(_field, value) when is_atom(value) or is_binary(value), do: :ok
  defp validate_identifier(field, value), do: {:error, {:invalid_extension_field, field, value}}

  defp validate_module(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, {:extension_module_not_loaded, module, reason}}
    end
  end

  defp validate_module(module), do: {:error, {:invalid_extension_module, module}}
end
