defmodule Ankole.Plugins.CloudConnectorsAdapter.Catalog do
  @moduledoc false
  alias Ankole.Connectors.ToolSpec
  alias Ankole.Plugins.CloudConnectorsAdapter.Definitions

  @directory Path.expand("../../../../catalog", __DIR__)
  @catalogs (for path <- Path.wildcard(Path.join(@directory, "*.json")), into: %{} do
               @external_resource path
               catalog = :json.decode(File.read!(path))
               {catalog["toolkit"], catalog}
             end)

  def tools(id) do
    catalog = Map.fetch!(@catalogs, id)

    Enum.map(catalog["tools"], fn tool ->
      %ToolSpec{
        toolkit: id,
        name: tool["name"],
        description: tool["description"],
        input_schema: tool["input_schema"],
        output_schema: tool["output_schema"],
        operation: %{"slug" => tool["slug"], "version" => catalog["version"]},
        annotations: tool["annotations"],
        upstream_auth: if(id in ~w(stripe sentry zendesk), do: :app_token, else: :adaptive_token),
        scopes: if(Definitions.oauth?(id), do: tool["scopes"], else: [])
      }
    end)
  end
end
