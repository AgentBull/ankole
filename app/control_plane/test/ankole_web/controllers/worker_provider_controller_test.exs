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
      conn |> recycle_api() |> get(~p"/api/v1/site/worker-provider-kinds") |> json_response(200)

    refute Enum.any?(response["worker_provider_kinds"], &(&1["kind"] == "vercel"))

    row = conn |> worker_providers() |> Enum.find(&(&1["provider_id"] == provider.provider_id))
    refute row["selectable"]
    assert row["config"] == provider.config
    assert row["stored_credentials"] == ["token"]

    response =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/site/worker-providers/saved-vercel/check")
      |> json_response(422)

    assert response["error"]["message"] =~ "vercel-worker-provider"
    assert response["error"]["message"] =~ "restart"

    %{principal: owner} = human_fixture()

    response =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents", %{
        worker_provider_id: provider.provider_id,
        handle: "inactive-plugin-agent",
        display_name: "Inactive",
        role: "Research Analyst",
        owner_principal_uid: owner.uid
      })
      |> json_response(422)

    assert response["error"]["code"] == "invalid_worker_provider"
    assert response["error"]["message"] =~ "vercel-worker-provider"

    assert response["error"]["details"] == [
             %{
               "path" => "kind",
               "message" => "requires active and configured Plugin vercel-worker-provider"
             }
           ]
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

  defp json_api(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
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
