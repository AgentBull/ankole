defmodule AnkoleWeb.JSONAPI.SiteWorkerProvidersTest do
  @moduledoc "Checks the Worker provider routes of the site JSON:API."
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ankole.AgentWorkers.Cloudflare
  alias Ankole.AgentWorkers.Lambda
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo

  @media_type "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()
    %{providers_before: Repo.all(from p in Provider, order_by: p.provider_id)}
  end

  defp send_v2(conn, method, path, body \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media_type)
    |> put_req_header("content-type", @media_type)
    |> dispatch(@endpoint, method, path, body && Ankole.JSON.encode!(body))
  end

  defp create(conn, attributes),
    do:
      send_v2(conn, :post, "/api/v2/site/worker-providers", %{
        data: %{type: "worker_provider", attributes: attributes}
      })

  defp update(conn, id, attributes),
    do:
      send_v2(conn, :patch, "/api/v2/site/worker-providers/#{id}", %{
        data: %{type: "worker_provider", attributes: attributes}
      })

  defp attributes(%{"data" => %{"attributes" => attributes}}), do: attributes

  defp details(response), do: get_in(response, ["errors", Access.at(0), "meta", "details"])

  test "admin saves the original YAML and sees every YAML error location", %{
    conn: conn,
    providers_before: providers_before
  } do
    conn = console_conn(conn)
    config = "# Operator comment\nnetwork: bridge\ncpus: 2\n"

    response = conn |> create(attrs(config)) |> json_response(201)

    assert %{"data" => %{"type" => "worker_provider", "id" => id}} = response
    assert id == Repo.get_by!(Provider, provider_id: "local").id

    assert %{
             "provider_id" => "local",
             "config" => ^config,
             "agent_count" => 0,
             "selectable" => true,
             "stored_credentials" => []
           } = attributes(response)

    rows =
      conn
      |> send_v2(:get, "/api/v2/site/worker-providers")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["attributes"])

    assert Enum.map(rows, & &1["provider_id"]) ==
             Enum.sort(["local" | Enum.map(providers_before, & &1.provider_id)])

    assert %{"config" => ^config} = Enum.find(rows, &(&1["provider_id"] == "local"))

    response =
      conn
      |> update("local", %{config: "network: bridge\nenv:\n  HOME: /elsewhere\nunknown: true\n"})
      |> json_response(422)

    assert %{"errors" => [%{"code" => "invalid_worker_provider_config"}]} = response
    assert Enum.any?(details(response), &(&1["path"] == "env.HOME" and &1["line"] == 3))
    assert Enum.any?(details(response), &(&1["path"] == "unknown" and &1["line"] == 4))
    assert Repo.get_by!(Provider, provider_id: "local").config == config

    response = conn |> update("local", %{config: "socket: /another.sock\n"}) |> json_response(422)

    assert [%{"path" => "socket", "message" => "cannot change after creation"}] =
             details(response)

    deleted =
      conn |> send_v2(:delete, "/api/v2/site/worker-providers/local") |> json_response(200)

    assert %{"provider_id" => "local"} = attributes(deleted)
    refute Repo.get_by(Provider, provider_id: "local")

    response =
      conn |> send_v2(:delete, "/api/v2/site/worker-providers/local") |> json_response(404)

    assert %{"errors" => [%{"code" => "not_found"}]} = response
  end

  test "a missing required field names its attribute", %{conn: conn} do
    conn = console_conn(conn)
    response = conn |> create(Map.delete(attrs("network: bridge\n"), :display_name))

    assert response.status in [400, 422]

    pointers =
      for error <- Jason.decode!(response.resp_body)["errors"],
          do: get_in(error, ["source", "pointer"])

    assert "/data/attributes/display_name" in pointers
  end

  test "credentials never enter a response and an empty replacement keeps the encrypted value", %{
    conn: conn
  } do
    conn = console_conn(conn)

    created =
      create(conn, %{
        provider_id: "edge",
        display_name: "Edge",
        kind: "cloudflare",
        config: Cloudflare.definition().example,
        credentials: %{adapterToken: "api-secret"}
      })

    assert %{"stored_credentials" => ["adapterToken"]} =
             created |> json_response(201) |> attributes()

    refute created.resp_body =~ "api-secret"
    encrypted = Repo.get_by!(Provider, provider_id: "edge").credentials
    refute inspect(encrypted) =~ "api-secret"

    updated = update(conn, "edge", %{credentials: %{adapterToken: ""}})

    assert %{"stored_credentials" => ["adapterToken"]} =
             updated |> json_response(200) |> attributes()

    assert Repo.get_by!(Provider, provider_id: "edge").credentials == encrypted

    listed = send_v2(conn, :get, "/api/v2/site/worker-providers")
    refute listed.resp_body =~ "api-secret"
    refute listed.resp_body =~ encrypted["adapterToken"]
  end

  test "null removes an optional credential, and credential rules name their fields", %{
    conn: conn
  } do
    conn = console_conn(conn)

    assert %{"stored_credentials" => ["accessKeyId", "secretAccessKey", "sessionToken"]} =
             conn
             |> create(%{
               provider_id: "aws",
               display_name: "AWS",
               kind: "lambda",
               config: Lambda.definition().example,
               credentials: %{
                 accessKeyId: "AKIAEXAMPLE",
                 secretAccessKey: "first-secret",
                 sessionToken: "first-session"
               }
             })
             |> json_response(201)
             |> attributes()

    response =
      conn
      |> update("aws", %{credentials: %{sessionToken: nil, secretAccessKey: ""}})
      |> json_response(200)

    assert attributes(response)["stored_credentials"] == ["accessKeyId", "secretAccessKey"]

    response = conn |> update("aws", %{credentials: %{accessKeyId: nil}}) |> json_response(422)

    assert details(response) == [
             %{
               "path" => "credentials",
               "message" =>
                 "accessKeyId and secretAccessKey are required together; sessionToken is optional"
             }
           ]

    response =
      conn
      |> update("aws", %{credentials: %{accessKeyId: nil, secretAccessKey: nil}})
      |> json_response(200)

    assert attributes(response)["stored_credentials"] == []

    {:ok, _provider} =
      Providers.create(%{
        provider_id: "edge",
        display_name: "Edge",
        kind: "cloudflare",
        config: Cloudflare.definition().example,
        credentials: %{"adapterToken" => "adapter-secret"}
      })

    response = conn |> update("edge", %{credentials: %{adapterToken: nil}}) |> json_response(422)

    assert details(response) == [
             %{"path" => "credentials.adapterToken", "message" => "is required"}
           ]
  end

  test "the API requires a Console browser session", %{
    conn: conn,
    providers_before: providers_before
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    assert conn |> get("/api/v2/site/worker-providers") |> json_response(401)
    assert Repo.all(from p in Provider, order_by: p.provider_id) == providers_before
  end

  defp attrs(config) do
    %{provider_id: "local", display_name: "Local", kind: "docker", config: config}
  end
end
