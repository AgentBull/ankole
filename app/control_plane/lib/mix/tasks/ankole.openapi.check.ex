defmodule Mix.Tasks.Ankole.Openapi.Check do
  @moduledoc """
  Checks that the browser applications' committed OpenAPI documents matches the control plane.
  """

  use Mix.Task

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.OpenApi, as: OpenAPI

  @shortdoc "Checks the committed browser OpenAPI documents"
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
      public_specs =
        [
          {"browser-v2", AnkoleWeb.JSONAPI.BrowserRouter},
          {"console-v2", AnkoleWeb.JSONAPI.ConsoleRouter},
          {"pod-v2", AnkoleWeb.JSONAPI.PodRouter},
          {"site-v2", AnkoleWeb.JSONAPI.SiteRouter}
        ]
        |> Enum.map(fn {name, module} -> {committed_spec_path(name), module} end)

      for {committed_path, module} <-
            public_specs ++ Application.get_env(:ankole, :openapi_specs, []) do
        generated = module.spec() |> OpenAPI.to_map() |> normalize()

        if args == ["--write"] do
          File.mkdir_p!(Path.dirname(committed_path))
          File.write!(committed_path, Ankole.JSON.encode!(generated) <> "\n")
          Mix.shell().info("Wrote #{committed_path}")
        else
          committed = committed_path |> File.read!() |> Ankole.JSON.decode!() |> normalize()

          if generated != committed do
            Mix.raise(
              "#{committed_path} does not match #{inspect(module)}; run mix ankole.openapi.check --write and regenerate the client"
            )
          end

          Mix.shell().info("#{Path.basename(committed_path)} OpenAPI document is current")
        end
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

  defp committed_spec_path(name) do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("../webapps/openapi/#{name}.json")
    |> Path.expand()
  end
end
