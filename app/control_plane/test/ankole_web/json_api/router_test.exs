defmodule AnkoleWeb.JSONAPI.RouterTest do
  @moduledoc "Checks the mounted JSON:API routers and the declarations of their domains."
  use AnkoleWeb.ConnCase, async: true

  alias AnkoleWeb.JSONAPI.{ConsoleRouter, SiteRouter}

  @routers [SiteRouter, ConsoleRouter]

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

  test "each routed action has a native authorizer rule and each target has an explicit resolver" do
    for router <- @routers, {resource, route} <- routes(router) do
      assert Ankole.AuthZ.Authorizer in Ash.Resource.Info.authorizers(resource)
      assert rule = Ankole.AuthZ.Dsl.rule(resource, route.action)
      params = Ankole.AuthZ.Dsl.params(resource)

      for [_, name] <- Regex.scan(~r/\{(\w+)\}/, rule.resource || "") do
        assert param = Enum.find(params, &(to_string(&1.name) == name))
        value = if param.type == :uuid, do: Ankole.Ecto.UUIDv7.autogenerate(), else: "probe"
        assert {:ok, normalized} = Ankole.AuthZ.Checks.GrantCheck.resolve(param.type, value)
        assert is_binary(normalized)
      end
    end
  end

  # AshJsonApi 1.7.1 `Info.derive_sort?/1` reads the option `:derive_sort`, so
  # it is always true. A list route derives a sort parameter unless the route
  # sets `derive_sort?: false`.
  test "Console read routes expose only their declared filters and sort" do
    for router <- @routers,
        {resource, route} <- routes(router),
        route.type in [:index, :get_related] do
      refute route.derive_filter? && AshJsonApi.Resource.Info.derive_filter?(resource),
             "#{inspect(resource)} #{route.name}"

      refute route.derive_sort?, "#{inspect(resource)} #{route.name}"
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
