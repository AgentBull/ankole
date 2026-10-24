defmodule AnkoleWeb.JSONAPI.NativeAuthorizationRoutesTest do
  use Ankole.DataCase, async: false
  import Plug.Conn
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ.Actor

  alias AnkoleWeb.JSONAPI.ConsoleRouter, as: Console
  alias AnkoleWeb.JSONAPI.SiteRouter, as: Site
  alias AnkoleWeb.JSONAPI.PodRouter, as: Pod

  test "every grant-protected HTTP route denies an ungranted Actor through Ash, without the legacy policy plug",
       %{tenant: tenant} do
    human = human_fixture().principal
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    actor = Actor.new(human)

    failures =
      for {router, file} <- [{Console, "console"}, {Site, "site"}, {Pod, "pod"}],
          {path, operations} <- specification(file)["paths"],
          {method, operation} <- operations,
          method in ["get", "post", "patch", "put", "delete"],
          protected?(router, operation["operationId"]),
          response = request(router, method, path, operation, specification(file), actor),
          response.status != 403,
          do:
            {method, path, response.status,
             Jason.decode!(response.resp_body)["errors"]
             |> Enum.map(&Map.take(&1, ["code", "detail", "source"]))}

    assert failures == [], inspect(failures, pretty: true, limit: :infinity)
  end

  test "all protected routed actions reject a disabled Actor through the production routers", %{
    tenant: tenant
  } do
    human = human_fixture().principal
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    actor = Actor.new(%{human | status: :disabled})

    failures =
      for {router, file} <- [{Console, "console"}, {Site, "site"}, {Pod, "pod"}],
          {path, operations} <- specification(file)["paths"],
          {method, operation} <- operations,
          method in ["get", "post", "patch", "put", "delete"],
          route = route_for(router, operation["operationId"]),
          route && Ankole.AuthZ.Dsl.rule(route.resource, route.action),
          response = request(router, method, path, operation, specification(file), actor),
          response.status != 403,
          do: {method, path, response.status, response.resp_body}

    assert failures == [], inspect(failures, pretty: true, limit: :infinity)
  end

  test "the production tenant router rejects absent tenant context", %{tenant: _tenant} do
    human = human_fixture().principal

    conn =
      Plug.Test.conn(:get, "/principals")
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", "application/vnd.api+json")
      |> assign(:authz_actor, Actor.new(human))

    response = Ankole.Repo.without_tenant(fn -> Console.call(conn, Console.init([])) end)
    assert response.status == 403
  end

  test "the production router rejects malformed UUID and authorization segments before dispatch",
       %{
         tenant: tenant
       } do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    actor = Actor.new(human_fixture().principal)

    for path <- ["/permission-grants/not-a-uuid", "/principal-groups/unsafe:target"] do
      response =
        Plug.Test.conn(:get, path)
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("accept", "application/vnd.api+json")
        |> assign(:authz_actor, actor)
        |> Console.call(Console.init([]))

      assert response.status == 400
      assert response.halted
      assert %{"errors" => [%{"code" => "invalid_target"}]} = Jason.decode!(response.resp_body)
    end
  end

  test "site grants use the group name from the selected data tenant", %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    actor = Actor.new(human_fixture().principal)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: Actor.uid(actor),
        resource_pattern: "site_console:principal_group:*:members",
        action: "read",
        condition: ~s(resource != "site_console:principal_group:restricted:members")
      })

    data_tenant = Ankole.DataCase.create_tenant()

    Ankole.Repo.with_tenant(data_tenant.id, fn ->
      {:ok, group} =
        Ankole.AuthZ.create_principal_group(%{name: "restricted", display_name: "Restricted"})

      {:ok, allowed} =
        Ankole.AuthZ.create_principal_group(%{name: "allowed", display_name: "Allowed"})

      for {selector, status} <- [{group.name, 403}, {group.id, 403}, {allowed.id, 200}] do
        response =
          Plug.Test.conn(:get, "/principal-groups/#{selector}/members")
          |> Plug.Test.init_test_session(%{})
          |> put_req_header("accept", "application/vnd.api+json")
          |> assign(:authz_actor, actor)
          |> Console.call(Console.init([]))

        assert response.status == status
        assert Ankole.Repo.tenant_id() == data_tenant.id
      end
    end)
  end

  defp route_for(router, name) do
    Enum.find_value(router.domains(), fn domain ->
      routes =
        AshJsonApi.Domain.Info.routes(domain) ++
          Enum.flat_map(Ash.Domain.Info.resources(domain), fn resource ->
            if AshJsonApi.Resource in Spark.extensions(resource),
              do:
                Enum.map(AshJsonApi.Resource.Info.routes(resource), &%{&1 | resource: resource}),
              else: []
          end)

      Enum.find(routes, &(&1.name == name))
    end)
  end

  defp protected?(router, name) do
    route = route_for(router, name)
    route && match?(%{check: :grant}, Ankole.AuthZ.Dsl.rule(route.resource, route.action))
  end

  defp specification(file) do
    Path.expand("../../../../webapps/openapi/#{file}-v2.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp request(router, method, path, operation, spec, actor) do
    prefix =
      case router do
        Console -> "/api/v2"
        Site -> "/api/v2/site"
        Pod -> "/api/v2/pod"
      end

    route = route_for(router, operation["operationId"])
    action = Ash.Resource.Info.action(route.resource, route.action)

    targets =
      Map.new(Regex.scan(~r/\{(\w+)\}/, path), fn [_, key] ->
        argument = Enum.find(action.arguments, &(to_string(&1.name) == key))

        value =
          if argument && argument.type == Ash.Type.Integer,
            do: to_string(Keyword.get(argument.constraints, :min, 1)),
            else: target(key, actor)

        {key, value}
      end)

    path = path |> String.replace_prefix(prefix, "")
    path = Regex.replace(~r/\{(\w+)\}/, path, fn _, key -> Map.fetch!(targets, key) end)

    query =
      for p <- operation["parameters"] || [],
          p["in"] == "query" and p["required"],
          do: {p["name"], query_sample(p, spec, actor)}

    query = URI.encode_query(query)
    body = get_in(operation, ["requestBody", "content", "application/vnd.api+json", "schema"])

    body =
      if body do
        body = sample(body, spec)
        data = Map.get(body, "data", %{})

        data =
          if Map.has_key?(data, "id"),
            do: Map.put(data, "id", targets["id"] || targets["uid"] || data["id"]),
            else: data

        data =
          Enum.reduce(["expires_at", "expiresAt"], data, fn key, data ->
            if Map.has_key?(data, key),
              do: Map.put(data, key, DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))),
              else: data
          end)

        data =
          if operation["operationId"] == "create_permission_grant",
            do:
              Map.update!(
                data,
                "attributes",
                &Map.merge(&1, %{
                  "principal_uid" => Actor.uid(actor),
                  "resource_pattern" => "tenant_console:**",
                  "action" => "read"
                })
              ),
            else: data

        Map.put(body, "data", data)
      end

    Plug.Test.conn(
      method,
      path <> if(query == "", do: "", else: "?" <> query),
      body && Jason.encode!(body)
    )
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> Plug.Test.init_test_session(%{})
    |> assign(:authz_actor, actor)
    |> router.call(router.init([]))
  end

  defp query_sample(%{"name" => "slug"}, _, actor), do: "people/" <> Actor.uid(actor)
  defp query_sample(param, spec, _), do: sample(param["schema"], spec)

  defp target(key, actor)
       when key in ["uid", "principal_uid", "agent_uid", "owner_uid", "owner_principal_uid"],
       do: Actor.uid(actor)

  defp target(key, _)
       when key in [
              "id",
              "client_id",
              "tenant_id",
              "credential_id",
              "job_id",
              "contradiction_id",
              "claim_id",
              "suggestion_id",
              "source_id",
              "cron_schedule_id",
              "restriction_id"
            ],
       do: Ankole.Ecto.UUIDv7.autogenerate()

  defp target("ref", _), do: Ankole.Ecto.UUIDv7.autogenerate()

  defp target("provider_id", _), do: "authorization-probe"

  defp target(key, _),
    do:
      if(String.ends_with?(key, "_id"),
        do: Ankole.Ecto.UUIDv7.autogenerate(),
        else: "authorization-probe"
      )

  defp sample(%{"$ref" => "#/" <> ref}, spec),
    do: sample(get_in(spec, String.split(ref, "/")), spec)

  defp sample(%{"enum" => [value | _]}, _), do: value

  defp sample(%{"anyOf" => choices}, spec),
    do: sample(Enum.find(choices, &(&1["type"] != "null")), spec)

  defp sample(%{"oneOf" => [choice | _]}, spec), do: sample(choice, spec)

  defp sample(%{"type" => "object"} = schema, spec) do
    props = schema["properties"] || %{}

    keys =
      Enum.uniq(
        (schema["required"] || []) ++
          Enum.filter(["attributes", "type"], &Map.has_key?(props, &1))
      )

    Map.new(keys, fn key -> {key, sample(props[key], spec)} end)
  end

  defp sample(%{"type" => "array"} = schema, spec),
    do: for(_ <- 1..(schema["minItems"] || 0)//1, do: sample(schema["items"], spec))

  defp sample(%{"type" => "boolean"}, _), do: true

  defp sample(%{"type" => type} = schema, _) when type in ["integer", "number"],
    do: schema["minimum"] || 1

  defp sample(%{"format" => "uuid"}, _), do: Ankole.Ecto.UUIDv7.autogenerate()

  defp sample(%{"format" => "date-time"}, _),
    do: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))

  defp sample(%{"type" => "string"} = schema, _),
    do: schema["example"] || String.duplicate("a", max(schema["minLength"] || 1, 1))

  defp sample(_, _), do: %{}
end
