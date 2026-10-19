defmodule AnkoleWeb.PodOpenAPITest do
  use ExUnit.Case, async: true

  test "every Pod HTTP route has a generated operation, including files and event streams" do
    spec = AnkoleWeb.InternalAPISpec.spec()

    for route <- AnkoleWeb.Router.__routes__(),
        String.starts_with?(route.path, "/.internal-apis/pod/") do
      path =
        route.path
        |> String.split("/")
        |> Enum.map(fn
          ":" <> name -> "{#{name}}"
          segment -> segment
        end)
        |> Enum.join("/")

      assert %OpenApiSpex.PathItem{} = item = spec.paths[path]
      assert %OpenApiSpex.Operation{} = Map.get(item, route.verb)
    end
  end
end
