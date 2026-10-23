defmodule AnkoleWeb.JSONAPI.RouterTest do
  @moduledoc "Checks the mounted JSON:API routers and the declarations of their domains."
  use AnkoleWeb.ConnCase, async: true

  alias AnkoleWeb.JSONAPI.{ConsoleRouter, Policy, SiteRouter}

  @routers [SiteRouter, ConsoleRouter]
  @scopes %{SiteRouter => :site, ConsoleRouter => :console}

  test "each router serves its OpenAPI document behind the Console session" do
    conn = console_conn(build_conn())

    for {path, title} <- [
          {"/api/v2/site/openapi.json", "Ankole site API v2"},
          {"/api/v2/openapi.json", "Ankole Console API v2"}
        ],
        accept <- ["application/json", "application/vnd.api+json"] do
      spec =
        conn
        |> recycle_api()
        |> put_req_header("accept", accept)
        |> get(path)
        |> json_response(200)

      assert spec["info"]["title"] == title
      assert spec["security"] == [%{"consoleSession" => []}]
      assert Map.keys(spec["components"]["securitySchemes"]) == ["consoleSession"]
    end

    assert %{"error" => %{"code" => "unauthorized"}} =
             build_conn() |> get("/api/v2/openapi.json") |> json_response(401)
  end

  test "an unknown v2 path gives a JSON:API not found document" do
    conn = console_conn(build_conn())

    for path <- ["/api/v2/no-such-resource", "/api/v2/site/no-such-resource"] do
      response = conn |> recycle_api() |> get(path)

      assert response.status == 404
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "application/vnd.api+json"
      assert %{"errors" => [%{"code" => "no_route_found"}]} = Jason.decode!(response.resp_body)
    end
  end

  test "each domain is in one router and the router gives its prefix" do
    domains = Enum.flat_map(@routers, & &1.domains())

    assert domains == Enum.uniq(domains)
    assert Enum.all?(domains, &is_nil(AshJsonApi.Domain.Info.prefix(&1)))
  end

  test "each route has a unique OpenAPI operation name" do
    for router <- @routers do
      names = router |> routes() |> Enum.map(fn {_resource, route} -> route.name end)

      assert Enum.all?(names, &is_binary/1)
      assert names == Enum.uniq(names)
    end
  end

  test "each route has one AuthZ rule and each rule has one route" do
    for router <- @routers do
      routes = routes(router)
      rules = Policy.rules(@scopes[router])
      keys = Enum.map(routes, fn {resource, route} -> Policy.rule_key(resource, route) end)

      assert Enum.sort(keys) == Enum.sort(Map.keys(rules)), inspect(router)

      for {key, {authz_resource, _action}} <- rules do
        {_resource, route} =
          Enum.find(routes, fn {resource, route} -> Policy.rule_key(resource, route) == key end)

        path_params = for ":" <> name <- String.split(route.route, "/"), do: name

        for [_match, name] <- Regex.scan(~r/\{(\w+)\}/, authz_resource) do
          assert name in path_params,
                 "#{authz_resource} names no path parameter of #{route.route}"
        end
      end
    end
  end

  test "each JSON:API resource derives no filter or sort parameters" do
    for module <- Ankole.TestModules.all(),
        Code.ensure_loaded?(module),
        Spark.Dsl.is?(module, Ash.Resource),
        AshJsonApi.Resource in Spark.extensions(module) do
      refute AshJsonApi.Resource.Info.derive_filter?(module), inspect(module)
      # AshJsonApi 1.7.1 `Info.derive_sort?/1` reads the wrong option name and
      # always gives true, so each read route also turns the sort off.
      refute Spark.Dsl.Extension.get_opt(module, [:json_api], :derive_sort?, true),
             inspect(module)
    end

    for router <- @routers,
        {resource, route} <- routes(router),
        route.type in [:index, :get_related] do
      refute route.derive_sort?, "#{inspect(resource)} #{route.route}"
    end
  end

  defp routes(router) do
    for domain <- router.domains(),
        route <-
          AshJsonApi.Domain.Info.routes(domain) ++
            Enum.flat_map(json_api_resources(domain), fn resource ->
              resource
              |> AshJsonApi.Resource.Info.routes()
              |> Enum.map(&%{&1 | resource: resource})
            end),
        do: {route.resource, route}
  end

  defp json_api_resources(domain),
    do:
      Enum.filter(
        Ash.Domain.Info.resources(domain),
        &(AshJsonApi.Resource in Spark.extensions(&1))
      )
end
