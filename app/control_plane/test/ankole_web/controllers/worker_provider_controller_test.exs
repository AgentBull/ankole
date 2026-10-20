defmodule AnkoleWeb.WorkerProviderControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query, only: [from: 2]
  alias Ankole.{Principals, Repo}
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  alias Ankole.AgentWorkers.Cloudflare
  alias Ankole.AgentWorkers.FunctionCompute
  alias Ankole.AgentWorkers.Lambda
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Vercel

  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.AgentWorker

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    %{providers_before: Repo.all(from p in Provider, order_by: p.provider_id)}
  end

  test "admin saves the original YAML, reads the type contract, and sees every YAML error location",
       %{conn: conn, providers_before: providers_before} do
    conn = console_conn(conn)
    response = get(conn, ~p"/api/v1/site/worker-provider-kinds") |> json_response(200)
    docker = Enum.find(response["worker_provider_kinds"], &(&1["kind"] == "docker"))
    assert Enum.sort(Map.keys(docker)) == ~w(credentials example kind)
    assert docker["example"] =~ "network:"
    config = "# Operator comment\nnetwork: bridge\ncpus: 2\n"

    response =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/site/worker-providers", attrs(config))
      |> json_response(201)

    assert %{
             "worker_provider" => %{
               "provider_id" => "local",
               "config" => ^config,
               "agent_count" => 0
             }
           } = response

    response =
      conn |> recycle_api() |> get(~p"/api/v1/site/worker-providers") |> json_response(200)

    rows = response["worker_providers"]

    assert Enum.sort(Enum.map(rows, & &1["provider_id"])) ==
             Enum.sort(["local" | Enum.map(providers_before, & &1.provider_id)])

    assert %{"config" => ^config} = Enum.find(rows, &(&1["provider_id"] == "local"))

    response =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/site/worker-providers/local", %{
        config: "network: bridge\nenv:\n  HOME: /elsewhere\nunknown: true\n"
      })
      |> json_response(422)

    errors = response["error"]["details"]
    assert Enum.any?(errors, &(&1["path"] == "env.HOME" and &1["line"] == 3))
    assert Enum.any?(errors, &(&1["path"] == "unknown" and &1["line"] == 4))
    assert Repo.get_by!(Provider, provider_id: "local").config == config

    response =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/site/worker-providers/local", %{config: "socket: /another.sock\n"})
      |> json_response(422)

    assert [%{"path" => "socket", "message" => "cannot change after creation"}] =
             response["error"]["details"]

    assert conn
           |> recycle_api()
           |> delete(~p"/api/v1/site/worker-providers/local")
           |> response(204) ==
             ""
  end

  test "credentials never enter a response and an empty replacement keeps the encrypted value", %{
    conn: conn
  } do
    conn = console_conn(conn)

    body = %{
      provider_id: "edge",
      display_name: "Edge",
      kind: "cloudflare",
      config: Ankole.AgentWorkers.Cloudflare.definition().example,
      credentials: %{adapterToken: "api-secret"}
    }

    created = conn |> recycle_api() |> post(~p"/api/v1/site/worker-providers", body)

    assert %{"worker_provider" => %{"credentials" => %{"adapterToken" => "********"}}} =
             json_response(created, 201)

    refute created.resp_body =~ "api-secret"
    encrypted = Repo.get_by!(Provider, provider_id: "edge").credentials
    refute inspect(encrypted) =~ "api-secret"

    updated =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/site/worker-providers/edge", %{credentials: %{adapterToken: ""}})

    assert json_response(updated, 200)["worker_provider"]["credentials"] == %{
             "adapterToken" => "********"
           }

    assert Repo.get_by!(Provider, provider_id: "edge").credentials == encrypted
    listed = conn |> recycle_api() |> get(~p"/api/v1/site/worker-providers")
    refute listed.resp_body =~ "api-secret"
    refute listed.resp_body =~ encrypted["adapterToken"]
  end

  test "creation selects a provider, migration assignment is one-time, and deleting Agents retain the provider reference",
       %{conn: conn} do
    conn = console_conn(conn)
    %{principal: owner} = human_fixture()

    agent_attrs = %{
      handle: "new-agent",
      display_name: "New Agent",
      role: "Researcher",
      owner_principal_uid: owner.uid
    }

    response =
      conn |> recycle_api() |> post(~p"/api/v1/agents", agent_attrs) |> json_response(422)

    assert response["error"]["code"] == "worker_provider_required"
    refute Repo.get_by(Principals.Agent, handle: "new-agent")
    {:ok, _provider} = Providers.create(Map.put(attrs("network: bridge\n"), :is_default, true))
    created = conn |> recycle_api() |> post(~p"/api/v1/agents", agent_attrs) |> json_response(200)
    assert created["agent"]["worker_provider_id"] == "local"
    agent_uid = created["agent"]["uid"]

    blank_provider =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent_uid}/worker-provider", %{provider_id: "  "})

    assert json_response(blank_provider, 422) == %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "provider_id is required",
               "details" => []
             }
           }

    assert Repo.get!(AgentWorker, agent_uid).provider_id == "local"
    listed = conn |> recycle_api() |> get(~p"/api/v1/agents") |> json_response(200)

    assert Enum.find(listed["agents"], &(&1["uid"] == agent_uid))["worker_provider_id"] ==
             "local"

    shown = conn |> recycle_api() |> get(~p"/api/v1/agents/#{agent_uid}") |> json_response(200)
    assert shown["agent"]["worker_provider_id"] == "local"
    {:ok, _provider} = Providers.create(%{attrs("network: bridge\n") | provider_id: "other"})

    response =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent_uid}/worker-provider", %{provider_id: "other"})
      |> json_response(409)

    assert response["error"]["code"] == "worker_provider_immutable"

    # This row is the state left by the migration, before an operator assigns it.
    Repo.get!(AgentWorker, agent_uid)
    |> Ecto.Changeset.change(provider_id: nil)
    |> Repo.update!()

    response =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent_uid}/worker-provider", %{provider_id: "local"})
      |> json_response(200)

    assert response == %{"agent_uid" => agent_uid, "provider_id" => "local"}

    Repo.get!(AgentWorker, agent_uid)
    |> Ecto.Changeset.change(state: "deleting")
    |> Repo.update!()

    response =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/site/worker-providers/local")
      |> json_response(409)

    assert response["error"]["code"] == "worker_provider_in_use"

    response =
      conn |> recycle_api() |> get(~p"/api/v1/site/worker-providers") |> json_response(200)

    assert Enum.find(response["worker_providers"], &(&1["provider_id"] == "local"))["agent_count"] ==
             1
  end

  test "null removes an optional credential, and credential rules name their fields", %{
    conn: conn
  } do
    conn = console_conn(conn)

    body = %{
      provider_id: "aws",
      display_name: "AWS",
      kind: "lambda",
      config: Lambda.definition().example,
      credentials: %{
        accessKeyId: "AKIAEXAMPLE",
        secretAccessKey: "first-secret",
        sessionToken: "first-session"
      }
    }

    assert %{"worker_provider" => %{"credentials" => %{"sessionToken" => "********"}}} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/site/worker-providers", Ankole.JSON.encode!(body))
             |> json_response(201)

    update = fn id, credentials ->
      conn
      |> recycle_api()
      |> patch(
        ~p"/api/v1/site/worker-providers/#{id}",
        Ankole.JSON.encode!(%{credentials: credentials})
      )
    end

    response = update.("aws", %{sessionToken: nil, secretAccessKey: ""}) |> json_response(200)

    assert response["worker_provider"]["credentials"] == %{
             "accessKeyId" => "********",
             "secretAccessKey" => "********"
           }

    response = update.("aws", %{accessKeyId: nil}) |> json_response(422)

    assert response["error"]["details"] == [
             %{
               "path" => "credentials",
               "message" =>
                 "accessKeyId and secretAccessKey are required together; sessionToken is optional"
             }
           ]

    response =
      update.("aws", %{accessKeyId: nil, secretAccessKey: nil}) |> json_response(200)

    assert response["worker_provider"]["credentials"] == %{}

    {:ok, _provider} =
      Providers.create(%{
        provider_id: "edge",
        display_name: "Edge",
        kind: "cloudflare",
        config: Cloudflare.definition().example,
        credentials: %{"adapterToken" => "adapter-secret"}
      })

    response = update.("edge", %{adapterToken: nil}) |> json_response(422)

    assert response["error"]["details"] == [
             %{"path" => "credentials.adapterToken", "message" => "is required"}
           ]
  end

  test "a failed check names the platform and its response", %{conn: conn} do
    conn = console_conn(conn)

    for key <- [:vercel_api_req_options, :lambda_api_req_options, :function_compute_req_options] do
      previous = Application.get_env(:ankole, key)
      Application.put_env(:ankole, key, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ankole, key, previous),
          else: Application.delete_env(:ankole, key)
      end)
    end

    for {id, kind, credentials} <- [
          {"vercel", Vercel, %{"token" => "vercel-token"}},
          {"aws", Lambda, %{"accessKeyId" => "AKIAEXAMPLE", "secretAccessKey" => "aws-secret"}},
          {"aliyun", FunctionCompute,
           %{"apiKey" => "api-key", "accessKeyId" => "ak", "accessKeySecret" => "ak-secret"}}
        ] do
      {:ok, _provider} =
        Providers.create(%{
          provider_id: id,
          display_name: id,
          kind: kind.definition().kind,
          config: kind.definition().example,
          credentials: credentials
        })
    end

    check = fn id, response ->
      Req.Test.stub(__MODULE__, response)

      conn
      |> recycle_api()
      |> get(~p"/api/v1/site/worker-providers/#{id}/check")
      |> json_response(422)
      |> get_in(["error", "message"])
    end

    assert check.("vercel", fn conn ->
             conn
             |> Plug.Conn.put_status(403)
             |> Req.Test.json(%{
               "error" => %{"code" => "forbidden", "message" => "Not authorized"}
             })
           end) == "The Vercel API returned HTTP 403 (forbidden): Not authorized"

    assert check.("aws", fn conn ->
             conn
             |> Plug.Conn.put_resp_header("x-amzn-errortype", "UnrecognizedClientException")
             |> Plug.Conn.put_status(403)
             |> Req.Test.json(%{"message" => "The security token is invalid."})
           end) == "The AWS Lambda API returned HTTP 403: UnrecognizedClientException"

    assert check.("aliyun", fn conn ->
             conn
             |> Plug.Conn.put_status(403)
             |> Req.Test.json(%{"Code" => "Forbidden.RAM", "Message" => "User not authorized."})
           end) ==
             "The Function Compute API returned HTTP 403 (Forbidden.RAM): User not authorized."

    for {id, platform} <- [
          {"vercel", "The Vercel API"},
          {"aws", "The AWS Lambda API"},
          {"aliyun", "The Function Compute API"}
        ] do
      assert check.(id, &Req.Test.transport_error(&1, :econnrefused)) ==
               "#{platform} is unreachable: connection refused"
    end
  end

  test "the API requires a Console browser session", %{
    conn: conn,
    providers_before: providers_before
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    assert conn |> get(~p"/api/v1/site/worker-providers") |> json_response(401)
    assert Repo.all(from p in Provider, order_by: p.provider_id) == providers_before
  end

  defp attrs(config) do
    %{provider_id: "local", display_name: "Local", kind: "docker", config: config}
  end
end
