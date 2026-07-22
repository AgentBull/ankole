defmodule Ankole.Brain.SourceConnectors do
  @moduledoc false

  @callbacks [availability: 1, revision: 1, export: 1]

  @spec fetch(String.t(), keyword()) :: {:ok, module()} | {:error, term()}
  def fetch(connector_id, opts \\ [])

  def fetch(connector_id, opts) when is_binary(connector_id) and is_list(opts) do
    module =
      Keyword.get_lazy(opts, :connector, fn ->
        :ankole
        |> Application.get_env(:brain_source_connectors, %{})
        |> connector_module(connector_id)
      end)

    if is_atom(module) and Code.ensure_loaded?(module) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      {:ok, module}
    else
      {:error, {:brain_source_connector_not_configured, connector_id}}
    end
  end

  def fetch(_connector_id, _opts), do: {:error, :invalid_brain_source_connector}

  defp connector_module(connectors, connector_id) when is_map(connectors) do
    Map.get(connectors, connector_id) || existing_atom_value(connectors, connector_id)
  end

  defp connector_module(connectors, connector_id) when is_list(connectors) do
    Keyword.get(connectors, String.to_existing_atom(connector_id))
  rescue
    ArgumentError -> nil
  end

  defp connector_module(_connectors, _connector_id), do: nil

  defp existing_atom_value(connectors, connector_id) do
    Map.get(connectors, String.to_existing_atom(connector_id))
  rescue
    ArgumentError -> nil
  end
end
