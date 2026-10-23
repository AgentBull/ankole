defmodule AnkoleWeb.WorkerProviderControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.{Principals, Repo}
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute
  alias Ankole.AgentWorkers.Lambda
  alias Ankole.AgentWorkers.Providers
  alias Ankole.Plugins.VercelWorkerProvider.Provider, as: Vercel

  alias Ankole.AgentWorkers.AgentWorker

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
  end

  test "an inactive Plugin keeps its provider visible and explains recovery", %{conn: conn} do
    alias Ankole.Plugins.Registry, as: PluginRegistry
    original = :sys.get_state(PluginRegistry)

    on_exit(fn ->
      :sys.replace_state(PluginRegistry, fn _state -> original end)

      Ankole.AgentWorkers.ProviderKind.refresh_from_specs(
        Map.values(original.discovered),
        Map.values(original.active)
      )
    end)

    conn = console_conn(conn)

    {:ok, provider} =
      Providers.create(%{
        provider_id: "saved-vercel",
        kind: "vercel",
        display_name: "Saved Vercel",
        config: Vercel.definition().example,
        credentials: %{"token" => "secret"}
      })

    {:ok, _} = Ankole.Plugins.put_configured_enabled("vercel-worker-provider", false)
    {:ok, snapshot} = PluginRegistry.prepare_snapshot()
    :sys.replace_state(PluginRegistry, fn _state -> snapshot end)

    Ankole.AgentWorkers.ProviderKind.refresh_from_specs(
      Map.values(snapshot.discovered),
      Map.values(snapshot.active)
    )

    response =
      conn |> json_api() |> get(~p"/api/v2/site/worker-provider-kinds") |> json_response(200)

    refute Enum.any?(response["worker_provider_kinds"], &(&1["kind"] == "vercel"))

    row = conn |> worker_providers() |> Enum.find(&(&1["provider_id"] == provider.provider_id))
    refute row["selectable"]
    assert row["config"] == provider.config
    assert row["stored_credentials"] == ["token"]

    response =
      conn
      |> json_api()
      |> get(~p"/api/v2/site/worker-providers/saved-vercel/check")
      |> json_response(422)

    assert hd(response["errors"])["detail"] =~ "vercel-worker-provider"
    assert hd(response["errors"])["detail"] =~ "restart"

    %{principal: owner} = human_fixture()

    response =
      conn
      |> json_api()
      |> post(
        "/api/v2/agents",
        Jason.encode!(%{
          data: %{
            worker_provider_id: provider.provider_id,
            handle: "inactive-plugin-agent",
            display_name: "Inactive",
            role: "Research Analyst",
            owner_principal_uid: owner.uid
          }
        })
      )
      |> json_response(422)

    assert [%{"code" => "worker_provider_plugin_inactive", "detail" => detail}] =
             response["errors"]

    assert detail =~ "vercel-worker-provider"
  end

  test "creation selects a provider, the migration assignment is one-time, and deleting Agents keep the provider reference",
       %{conn: conn} do
    conn = console_conn(conn)
    %{principal: owner} = human_fixture()

    agent_attrs = %{
      handle: "new-agent",
      display_name: "New Agent",
      role: "Researcher",
      owner_principal_uid: owner.uid
    }

    assert [%{"code" => "worker_provider_required"}] =
             conn |> post_agent(agent_attrs) |> json_response(422) |> Map.fetch!("errors")

    refute Repo.get_by(Principals.Agent, handle: "new-agent")
    {:ok, _provider} = Providers.create(Map.put(attrs("network: bridge\n"), :is_default, true))
    created = conn |> post_agent(agent_attrs) |> json_response(201)
    assert created["worker_provider_id"] == "local"
    agent_uid = created["uid"]

    assert %{"errors" => [%{"source" => %{"pointer" => "/data/provider_id"}}]} =
             conn |> assign_provider(agent_uid, nil) |> json_response(400)

    assert Repo.get!(AgentWorker, agent_uid).provider_id == "local"

    assert %{"data" => %{"attributes" => %{"worker_provider_id" => "local"}}} =
             conn |> json_api() |> get("/api/v2/agents/#{agent_uid}") |> json_response(200)

    {:ok, _provider} = Providers.create(%{attrs("network: bridge\n") | provider_id: "other"})

    assert [%{"code" => "worker_provider_immutable"}] =
             conn
             |> assign_provider(agent_uid, "other")
             |> json_response(409)
             |> Map.fetch!("errors")

    assert [%{"code" => "not_found"}] =
             conn
             |> assign_provider(agent_uid, "missing")
             |> json_response(404)
             |> Map.fetch!("errors")

    # This row is the state left by the migration, before an operator assigns it.
    Repo.get!(AgentWorker, agent_uid)
    |> Ecto.Changeset.change(provider_id: nil)
    |> Repo.update!()

    assert %{"agent_uid" => ^agent_uid, "provider_id" => "local"} =
             conn |> assign_provider(agent_uid, "local") |> json_response(200)

    Repo.get!(AgentWorker, agent_uid)
    |> Ecto.Changeset.change(state: :deleting)
    |> Repo.update!()

    response =
      conn
      |> json_api()
      |> delete(~p"/api/v2/site/worker-providers/local")
      |> json_response(409)

    assert [%{"code" => "worker_provider_in_use"}] = response["errors"]
    assert Enum.find(worker_providers(conn), &(&1["provider_id"] == "local"))["agent_count"] == 1
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
      |> json_api()
      |> get(~p"/api/v2/site/worker-providers/#{id}/check")
      |> json_response(422)
      |> then(&hd(&1["errors"])["detail"])
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

  defp json_api(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  defp post_agent(conn, attrs),
    do: conn |> json_api() |> post("/api/v2/agents", Jason.encode!(%{data: attrs}))

  defp assign_provider(conn, agent_uid, provider_id) do
    conn
    |> json_api()
    |> put(
      "/api/v2/agents/#{agent_uid}/worker-provider",
      Jason.encode!(%{data: %{provider_id: provider_id}})
    )
  end

  defp worker_providers(conn) do
    conn
    |> json_api()
    |> get(~p"/api/v2/site/worker-providers")
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.map(& &1["attributes"])
  end

  defp attrs(config) do
    %{provider_id: "local", display_name: "Local", kind: "docker", config: config}
  end
end
