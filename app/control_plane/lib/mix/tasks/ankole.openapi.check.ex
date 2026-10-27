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
      for {name, module} <-
            [
              {"browser-v2", AnkoleWeb.JSONAPI.BrowserRouter},
              {"console-v2", AnkoleWeb.JSONAPI.ConsoleRouter},
              {"pod-v2", AnkoleWeb.JSONAPI.PodRouter},
              {"site-v2", AnkoleWeb.JSONAPI.SiteRouter}
            ] ++ edition_specs() do
        committed_path = committed_spec_path(name)
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

          Mix.shell().info("#{name} OpenAPI document is current")
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

  defp edition_specs do
    for {name, module} <- [
          {"saas-v2", Ankole.SaaSWeb.JSONAPIRouter},
          {"saas-pod-v2", Ankole.SaaSWeb.PodJSONAPIRouter},
          {"saas-site-v2", Ankole.SaaSWeb.SiteJSONAPIRouter}
        ],
        Code.ensure_loaded?(module),
        do: {name, module}
  end

  defp committed_spec_path(name) when name in ["saas-v2", "saas-pod-v2", "saas-site-v2"] do
    Path.expand(
      "../../internals/webapps/openapi/#{name}.json",
      Path.dirname(Mix.Project.project_file())
    )
  end

  defp committed_spec_path(name) do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("../webapps/openapi/#{name}.json")
    |> Path.expand()
  end
end
