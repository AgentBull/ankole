defmodule AnkoleWeb.JSONAPI.SchedulesTest do
  @moduledoc "Checks the cron schedule and checkback routes of `/api/v2`."
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ.Grant
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Setup.Config, as: SetupConfig

  @json_api "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin lists, pauses, resumes, and removes the cron schedules of one Agent", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    morning = cron_schedule!(agent.uid, "session-a", "morning-report")
    evening = cron_schedule!(agent.uid, "session-b", "evening-report")
    foreign = cron_schedule!(other_agent.uid, "session-c", "other-report")
    conn = console_conn(conn)

    everything = conn |> request(:get, "/api/v2/cron-schedules") |> json_response(200)

    assert MapSet.new(everything["data"], & &1["id"]) ==
             MapSet.new([morning.id, evening.id, foreign.id])

    list =
      conn |> request(:get, "/api/v2/cron-schedules?agent=#{agent.uid}") |> json_response(200)

    assert MapSet.new(list["data"], & &1["id"]) == MapSet.new([morning.id, evening.id])

    assert MapSet.new(list["data"], & &1["attributes"]["owner_session_id"]) ==
             MapSet.new(["session-a", "session-b"])

    assert Enum.all?(
             list["data"],
             &(&1["attributes"]["execution_session_id"] == "cron:" <> &1["id"])
           )

    shown =
      conn
      |> request(:get, "/api/v2/agents/#{agent.uid}/cron-schedules/#{evening.id}")
      |> json_response(200)

    assert shown["data"]["attributes"]["name"] == "evening-report"

    assert conn
           |> request(:get, "/api/v2/agents/#{other_agent.uid}/cron-schedules/#{evening.id}")
           |> json_response(404)

    paused =
      conn
      |> request(:post, "/api/v2/agents/#{agent.uid}/cron-schedules/#{evening.id}/pause")
      |> json_response(201)

    assert %{"id" => evening_id, "status" => "paused", "next_fire_at" => nil} = paused
    assert evening_id == evening.id

    assert %{"status" => "active"} =
             conn
             |> request(:post, "/api/v2/agents/#{agent.uid}/cron-schedules/#{evening.id}/resume")
             |> json_response(201)

    for {method, path} <- [
          {:delete, "/api/v2/agents/#{other_agent.uid}/cron-schedules/#{morning.id}"},
          {:post, "/api/v2/agents/#{other_agent.uid}/cron-schedules/#{morning.id}/pause"},
          {:delete, "/api/v2/agents/#{agent.uid}/cron-schedules/#{Ecto.UUID.generate()}"}
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> request(method, path) |> json_response(404)
    end

    removed =
      conn
      |> request(:delete, "/api/v2/agents/#{agent.uid}/cron-schedules/#{morning.id}")
      |> json_response(200)

    assert removed["status"] == "deleted"

    remaining =
      conn |> request(:get, "/api/v2/cron-schedules?agent=#{agent.uid}") |> json_response(200)

    assert [%{"id" => remaining_id}] = remaining["data"]
    assert remaining_id == evening.id
  end

  test "creation records the Console Principal and update replaces the targets", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {conn, admin_uid} = console_conn_with_principal(conn)

    digest_id = conversation!(agent.uid, "lark:chat:digest")
    archive_id = conversation!(agent.uid, "lark:chat:archive")

    created =
      conn
      |> request(
        :post,
        "/api/v2/agents/#{agent.uid}/cron-schedules",
        cron_body(agent.uid, "session-a", "digest")
      )
      |> json_response(201)

    assert %{"id" => schedule_id, "owner_session_id" => "session-a", "status" => "active"} =
             created

    assert created["execution_session_id"] == "cron:" <> schedule_id
    assert %{"kind" => "operator_api", "principal_uid" => principal_ref} = created["created_by"]
    assert principal_ref =~ admin_uid

    assert created["delivery"]["targets"] == [
             %{"binding_name" => "lark", "conversation_id" => digest_id}
           ]

    targets = [
      %{"binding_name" => "lark", "conversation_id" => digest_id},
      %{"binding_name" => "lark-record", "conversation_id" => archive_id}
    ]

    updated =
      conn
      |> request(:patch, "/api/v2/agents/#{agent.uid}/cron-schedules/#{schedule_id}", %{
        "delivery" => %{"targets" => targets}
      })
      |> json_response(200)

    assert updated["delivery"]["targets"] == targets
    assert updated["name"] == "digest"

    assert %{"errors" => [%{"source" => %{"pointer" => "/data/owner_session_id"}}]} =
             conn
             |> request(
               :post,
               "/api/v2/agents/#{agent.uid}/cron-schedules",
               Map.delete(cron_body(agent.uid, "session-a", "second-digest"), "owner_session_id")
             )
             |> json_response(400)

    assert %{"errors" => [%{"code" => "cron_task_required"}]} =
             conn
             |> request(
               :post,
               "/api/v2/agents/#{agent.uid}/cron-schedules",
               Map.put(cron_body(agent.uid, "session-a", "third-digest"), "payload", %{})
             )
             |> json_response(422)
  end

  test "admin manually runs a cron schedule once for one idempotency key", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    schedule = cron_schedule!(agent.uid, "session-a", "manual-digest")
    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}/cron-schedules/#{schedule.id}/runs"

    first =
      conn
      |> request(:post, path, %{idempotency_key: "console-manual-digest"})
      |> json_response(201)

    assert %{"id" => event_id, "kind" => "cron_fire", "cron_schedule_id" => schedule_id} = first
    assert schedule_id == schedule.id

    assert %{"id" => ^event_id} =
             conn
             |> request(:post, path, %{idempotency_key: "console-manual-digest"})
             |> json_response(201)

    runs = conn |> request(:get, path) |> json_response(200)
    assert [%{"id" => listed_id}] = runs["data"]
    assert listed_id == to_string(event_id)

    assert %{"data" => []} =
             conn
             |> request(:get, "/api/v2/agents/agt_other/cron-schedules/#{schedule.id}/runs")
             |> json_response(200)
  end

  test "admin lists and cancels the checkbacks of one Agent", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = checkback!(agent.uid, "session-a", "check the build")
    second = checkback!(agent.uid, "session-b", "check the deploy")
    foreign = checkback!(other_agent.uid, "session-c", "check the backup")
    conn = console_conn(conn)

    everything = conn |> request(:get, "/api/v2/checkbacks") |> json_response(200)

    assert MapSet.new(everything["data"], & &1["id"]) ==
             MapSet.new(Enum.map([first, second, foreign], &to_string(&1.id)))

    list = conn |> request(:get, "/api/v2/checkbacks?agent=#{agent.uid}") |> json_response(200)

    assert MapSet.new(list["data"], & &1["id"]) ==
             MapSet.new([to_string(first.id), to_string(second.id)])

    assert MapSet.new(list["data"], & &1["attributes"]["session_id"]) ==
             MapSet.new(["session-a", "session-b"])

    for path <- [
          "/api/v2/agents/#{other_agent.uid}/checkbacks/#{first.id}",
          "/api/v2/agents/#{agent.uid}/checkbacks/9007199254740991"
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> request(:delete, path) |> json_response(404)
    end

    assert %{"status" => "cancelled"} =
             conn
             |> request(:delete, "/api/v2/agents/#{agent.uid}/checkbacks/#{first.id}")
             |> json_response(200)
  end

  test "a schedule write needs the update grant of the owning Agent", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    schedule = cron_schedule!(agent.uid, "session-a", "granted-digest")
    {conn, admin_uid} = console_conn_with_principal(conn)

    Repo.delete_all(
      from grant in Grant,
        where:
          grant.resource_pattern in ["site_console:**", "tenant_console:**"] or
            grant.principal_uid == ^admin_uid
    )

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn
             |> request(:post, "/api/v2/agents/#{agent.uid}/cron-schedules/#{schedule.id}/pause")
             |> json_response(403)

    assert {:ok, %{status: :active}} = Schedule.get_cron_schedule(schedule.id)
  end

  test "missing browser session is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v2/cron-schedules") |> json_response(401)
  end

  defp request(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @json_api)
    |> put_req_header("content-type", @json_api)
    |> dispatch(@endpoint, method, path, if(data, do: Jason.encode!(%{data: data}), else: ""))
  end

  defp cron_body(agent_uid, owner_session_id, name) do
    conversation_id = conversation!(agent_uid, "lark:chat:#{name}")

    %{
      "owner_session_id" => owner_session_id,
      "binding_name" => "lark",
      "name" => name,
      "schedule" => %{"kind" => "cron", "expression" => "0 9 * * *"},
      "timezone" => "Asia/Shanghai",
      "payload" => %{"task" => "console test task for #{name}"},
      "delivery" => %{
        "targets" => [
          %{"binding_name" => "lark", "conversation_id" => conversation_id}
        ]
      },
      "idempotency_key" => "console-test-#{name}"
    }
  end

  defp cron_schedule!(agent_uid, owner_session_id, name) do
    attrs =
      agent_uid
      |> cron_body(owner_session_id, name)
      |> Map.put("agent_uid", agent_uid)

    assert {:ok, %{cron_schedule: schedule}} =
             Schedule.create_cron_schedule(attrs,
               created_by: %{
                 "principal_uid" =>
                   to_string(%Ankole.ActorRef{
                     tenant_id: Ankole.Repo.tenant_id!(),
                     uid: agent_uid
                   })
               }
             )

    schedule
  end

  defp conversation!(agent_uid, provider_id) do
    assert {:ok, conversation} =
             Ankole.Repo.transact(fn ->
               Ankole.Conversations.External.observe_conversation_in_tx(
                 %{agent_uid: agent_uid},
                 %{
                   provider_conversation_id: provider_id,
                   external_kind: :im_group,
                   title: provider_id,
                   reply_mode: :entry
                 },
                 DateTime.utc_now(:microsecond)
               )
             end)

    conversation.id
  end

  defp checkback!(agent_uid, session_id, reason) do
    assert {:ok, %{scheduled_event: event}} =
             Schedule.create_check_back_later(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
               "agent_uid" => agent_uid,
               "session_id" => session_id,
               "binding_name" => "lark",
               "tool_call_id" => "console-test-#{session_id}",
               "idempotency_key" => "console-test-#{session_id}",
               "schedule" => %{
                 "after" => %{"value" => 30, "unit" => "minute"},
                 "timezone" => "Asia/Shanghai"
               },
               "reason" => reason,
               "check" => reason,
               "reply_route" => %{
                 "conversation_id" => conversation!(agent_uid, "lark:chat:#{session_id}")
               }
             })

    event
  end
end
