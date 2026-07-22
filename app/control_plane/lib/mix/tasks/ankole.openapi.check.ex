defmodule Mix.Tasks.Ankole.Openapi.Check do
  @moduledoc """
  Checks that the console's committed OpenAPI document matches the control plane.
  """

  use Mix.Task

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.OpenApi, as: OpenAPI

  @shortdoc "Checks the committed console OpenAPI document"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) when args in [[], ["--write"]] do
    {:ok, _apps} = Application.ensure_all_started(:phoenix)
    endpoint_config = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)

    Application.put_env(
      :ankole,
      AnkoleWeb.Endpoint,
      Keyword.delete(endpoint_config, :cache_static_manifest)
    )

    {:ok, supervisor} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Ankole.PubSub}, AnkoleWeb.Endpoint],
        strategy: :one_for_one
      )

    try do
      committed_path = committed_spec_path()
      generated = AnkoleWeb.APISpec.spec() |> OpenAPI.to_map() |> normalize()

      if args == ["--write"] do
        File.write!(committed_path, Ankole.JSON.encode!(generated) <> "\n")
        Mix.shell().info("Wrote #{committed_path}")
      else
        committed = committed_path |> File.read!() |> Ankole.JSON.decode!() |> normalize()

        if generated != committed do
          Mix.raise(
            "#{committed_path} does not match AnkoleWeb.APISpec; run mix ankole.openapi.check --write and regenerate the client"
          )
        end

        Mix.shell().info("Console OpenAPI document is current")
      end
    after
      Supervisor.stop(supervisor)
      Application.put_env(:ankole, AnkoleWeb.Endpoint, endpoint_config)
    end
  end

  def run(_args), do: Mix.raise("usage: mix ankole.openapi.check [--write]")

  defp normalize(%{} = spec) do
    spec
    |> Ankole.JSON.encode!()
    |> Ankole.JSON.decode!()
    |> Map.delete("servers")
  end

  defp committed_spec_path do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("../webapps/openapi/console.json")
    |> Path.expand()
  end
end
