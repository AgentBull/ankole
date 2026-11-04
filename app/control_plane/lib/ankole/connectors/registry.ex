defmodule Ankole.Connectors.Registry do
  @moduledoc "Resolves the explicit tool contracts contributed by active plugins."

  def adapter(id) do
    with {:ok, declaration} <- Ankole.Plugins.Registry.fetch_adapter("connectors.connector", id),
         do: {:ok, declaration.module}
  end

  def toolkit(id) do
    Enum.find_value(declarations(), {:error, :toolkit_not_found}, fn declaration ->
      tools = Enum.filter(declaration.module.tools(), &(&1.toolkit == id))
      if tools != [], do: {:ok, declaration.module, tools}
    end)
  end

  def plugin_id(toolkit) do
    Enum.find_value(declarations(), fn declaration ->
      if Enum.any?(declaration.module.tools(), &(&1.toolkit == toolkit)), do: declaration.id
    end)
  end

  def catalog, do: Ankole.Connectors.Catalog.list()

  defp declarations, do: Ankole.Plugins.Registry.adapter_declarations("connectors.connector")
end
