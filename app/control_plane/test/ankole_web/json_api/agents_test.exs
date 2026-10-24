defmodule AnkoleWeb.JSONAPI.AgentsTest do
  @moduledoc "Checks the v2 Agent routes: the records, the writes, and the Worker routes."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Conversations
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  @media "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin creates, lists, updates, disables, re-enables, and deletes an agent", %{conn: conn} do
    %{principal: owner} = human_fixture(%{uid: unique_uid("agent-owner")})
    provider = worker_provider_fixture()
    {conn, operator_uid} = console_conn_with_principal(conn)
    owner_uid = owner.uid

    response =
      send_v2(conn, :post, "/api/v2/agents", %{
        "worker_provider_id" => provider.provider_id,
        "handle" => "Console-Agent",
        "display_name" => "Console Agent",
        "role" => "Research Operator",
        "owner_principal_uid" => owner.uid,
        "options" => %{"ai_agent" => %{"temperature" => 0.2}}
      })

    assert %{
             "uid" => agent_uid,
             "handle" => "console-agent",
             "display_name" => "Console Agent",
             "role" => "Research Operator",
             "status" => "active",
             "worker_provider_id" => worker_provider_id,
             "options" => %{"ai_agent" => %{"temperature" => 0.2}},
             "owner_principal_uid" => ^owner_uid,
             "group_memory_disclosure_mode" => "strict",
             "created_by" => %{"uid" => ^operator_uid, "tenant_id" => tenant_id}
           } = json_response(response, 201)

    assert worker_provider_id == provider.provider_id
    assert tenant_id == Repo.tenant_id()
    assert {:ok, _} = Ecto.UUID.cast(agent_uid)

    conversation_ids =
      for _ <- 1..2 do
        id = Ecto.UUID.generate()

        assert {:ok, _} =
                 Ankole.ConversationsFixtures.create(owner.uid, %{
                   conversation_id: id,
                   message_id: Ecto.UUID.generate(),
                   agent_uid: agent_uid,
                   text: "Help me review this case."
                 })

        :ok = Conversations.Events.subscribe(id)
        id
      end

    assert %{"data" => agents} = conn |> send_v2(:get, "/api/v2/agents") |> json_response(200)

    assert %{"type" => "agent", "attributes" => %{"status" => "active"}} =
             Enum.find(agents, &(&1["id"] == agent_uid))

    assert %{"display_name" => "Console Agent Updated", "role" => "Customer Success Operator"} =
             conn
             |> send_v2(:patch, "/api/v2/agents/#{agent_uid}", %{
               "display_name" => "Console Agent Updated",
               "role" => "Customer Success Operator"
             })
             |> json_response(200)

    assert %{
             "data" => %{
               "id" => ^agent_uid,
               "attributes" => %{"display_name" => "Console Agent Updated", "handle" => _}
             }
           } = conn |> send_v2(:get, "/api/v2/agents/#{agent_uid}") |> json_response(200)

    assert %{"status" => "disabled"} =
             conn |> send_v2(:delete, "/api/v2/agents/#{agent_uid}") |> json_response(200)

    for id <- conversation_ids, do: assert_receive({:conversation_event, ^id, :status})

    # A disabled agent stays listed so the operator can re-enable or delete it.
    assert %{"data" => agents} = conn |> send_v2(:get, "/api/v2/agents") |> json_response(200)

    assert Enum.any?(
             agents,
             &(&1["id"] == agent_uid and &1["attributes"]["status"] == "disabled")
           )

    assert %{"status" => "active"} =
             conn |> send_v2(:post, "/api/v2/agents/#{agent_uid}/enable") |> json_response(201)

    for id <- conversation_ids, do: assert_receive({:conversation_event, ^id, :status})

    # Deleting requires disabling first; the second delete removes the row.
    assert %{"status" => "disabled"} =
             conn |> send_v2(:delete, "/api/v2/agents/#{agent_uid}") |> json_response(200)

    for id <- conversation_ids, do: assert_receive({:conversation_event, ^id, :status})

    assert %{"handle" => "console-agent"} =
             conn |> send_v2(:delete, "/api/v2/agents/#{agent_uid}") |> json_response(200)

    for id <- conversation_ids do
      assert_receive {:conversation_event, ^id, :status}
      assert {:error, :conversation_not_found} = Conversations.get(owner.uid, id)
    end

    assert %{"data" => agents} = conn |> send_v2(:get, "/api/v2/agents") |> json_response(200)
    refute Enum.any?(agents, &(&1["id"] == agent_uid))

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn |> send_v2(:get, "/api/v2/agents/#{agent_uid}") |> json_response(404)
  end

  test "an agent write does not change a human principal with the same path shape", %{
    conn: conn
  } do
    %{principal: human} = human_fixture(%{uid: unique_uid("not-agent")})
    conn = console_conn(conn)

    for {method, path} <- [
          {:delete, "/api/v2/agents/#{human.uid}"},
          {:post, "/api/v2/agents/#{human.uid}/enable"}
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> send_v2(method, path) |> json_response(404)
    end

    assert {:ok, %{status: :active}} = Ankole.Principals.get_principal(human.uid)
  end

  test "agent creation requires a nonblank display name and refuses a token quota", %{
    conn: conn
  } do
    %{principal: owner} = human_fixture(%{uid: unique_uid("agent-owner")})
    provider = worker_provider_fixture()
    conn = console_conn(conn)

    for display_name <- [nil, "   "] do
      response =
        send_v2(conn, :post, "/api/v2/agents", %{
          "handle" => unique_uid("blank-display-name"),
          "display_name" => display_name,
          "role" => "Research Analyst",
          "owner_principal_uid" => owner.uid
        })

      assert %{"errors" => [%{"source" => %{"pointer" => pointer}} | _]} =
               json_response(response, 400)

      assert pointer =~ ~r{^/data/(attributes/)?display_name$}
    end

    response =
      send_v2(conn, :post, "/api/v2/agents", %{
        "worker_provider_id" => provider.provider_id,
        "handle" => unique_uid("quota-at-creation"),
        "display_name" => "Quota At Creation",
        "role" => "Research Analyst",
        "owner_principal_uid" => owner.uid,
        "options" => %{"ai_agent" => %{"token_quota" => %{"period_days" => 0}}}
      })

    assert %{"errors" => [%{"code" => "token_quota_not_writable_at_creation"}]} =
             json_response(response, 422)
  end

  test "the agent update keeps the ai_agent options and refuses to write them", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    {:ok, _quota} =
      Ankole.AIAgent.TokenQuota.put(agent.uid, %{
        "period_days" => 7,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000
      })

    assert %{"options" => %{"ai_agent" => %{"token_quota" => _}}} =
             conn
             |> send_v2(:patch, "/api/v2/agents/#{agent.uid}", %{"options" => %{}})
             |> json_response(200)

    response =
      send_v2(conn, :patch, "/api/v2/agents/#{agent.uid}", %{
        "options" => %{"ai_agent" => %{"token_quota" => %{"period_days" => 0}}}
      })

    assert %{"errors" => [%{"code" => "ai_agent_options_not_writable"}]} =
             json_response(response, 422)
  end

  test "admin lists the Worker of each Agent without its credential or route", %{conn: conn} do
    %{principal: ready_agent} = agent_fixture()
    %{principal: idle_agent} = agent_fixture()
    route = "route-#{System.unique_integer([:positive])}"
    {:ok, _worker} = Ankole.SessionsCase.admit_worker(route, %{worker_id: ready_agent.uid})

    assert %{"data" => workers} =
             conn
             |> console_conn()
             |> send_v2(:get, "/api/v2/agent-workers")
             |> json_response(200)

    by_agent = Map.new(workers, &{&1["id"], &1["attributes"]})

    assert %{"state" => "ready", "generation" => generation, "image" => image} =
             by_agent[ready_agent.uid]

    assert is_binary(generation) and is_binary(image)
    assert is_binary(by_agent[ready_agent.uid]["last_worker_heartbeat_at"])
    assert %{"state" => "absent", "generation" => nil} = by_agent[idle_agent.uid]

    agent_uids = Enum.map(workers, & &1["id"])
    assert agent_uids == Enum.sort(agent_uids)

    for %{"attributes" => attributes} <- workers do
      assert Map.keys(attributes) |> Enum.sort() ==
               ~w(capacity drain_reason generation image last_error last_worker_heartbeat_at load provider_id state state_changed_at)
    end
  end

  test "the routes require a Console browser session", %{conn: conn} do
    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> get("/api/v2/agents") |> json_response(401)
  end

  # The v2 client sends JSON:API documents. A generic action reads its
  # arguments from `data`.
  defp send_v2(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media)
    |> put_req_header("content-type", @media)
    |> dispatch(@endpoint, method, path, data && Jason.encode!(%{data: data}))
  end
end
