defmodule AnkoleWeb.InternalAPISpecTest do
  use ExUnit.Case, async: true

  test "private operations are derived from the real router without a public document route" do
    private = AnkoleWeb.InternalAPISpec.spec()

    routes =
      AnkoleWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/.internal-apis/"))
      |> Enum.reject(&(&1.plug_opts == :events))

    for route <- routes do
      path = Regex.replace(~r/:([a-z_]+)/, route.path, "{\\1}")
      assert Map.fetch!(private.paths, path) |> Map.fetch!(route.verb)
    end

    refute Enum.any?(AnkoleWeb.Router.__routes__(), &(&1.plug == AnkoleWeb.InternalAPISpec))
    refute Map.has_key?(private.paths, "/api/v1/agents/{agent_uid}/files")
  end
end
