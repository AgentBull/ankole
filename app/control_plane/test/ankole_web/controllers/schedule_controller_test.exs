defmodule AnkoleWeb.ScheduleControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import OpenApiSpex.TestAssertions

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Schedule
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists, pauses and removes cron schedules across every session of one agent", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    morning = cron_schedule!(agent.uid, "session-a", "morning-report")
    evening = cron_schedule!(agent.uid, "session-b", "evening-report")
    foreign = cron_schedule!(other_agent.uid, "session-c", "other-report")

    api_spec = AnkoleWeb.APISpec.spec()
    conn = bearer_conn(conn)

    everything =
      conn
      |> get(~p"/api/v1/cron-schedules")
      |> json_response(200)

    assert_schema(everything, "ScheduleCronScheduleListResponse", api_spec)

    assert MapSet.new(everything["cron_schedules"], & &1["id"]) ==
             MapSet.new([morning.id, evening.id, foreign.id])

    list =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/cron-schedules?agent=#{agent.uid}")
      |> json_response(200)

    assert_schema(list, "ScheduleCronScheduleListResponse", api_spec)
    assert %{"cron_schedules" => schedules} = list
    assert MapSet.new(schedules, & &1["id"]) == MapSet.new([morning.id, evening.id])

    assert MapSet.new(schedules, & &1["owner_session_id"]) ==
             MapSet.new(["session-a", "session-b"])

    paused =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/agents/#{agent.uid}/cron-schedules/#{evening.id}/pause")
      |> json_response(200)

    assert get_in(paused, ["cron_schedule", "status"]) == "paused"

    assert conn
           |> recycle_bearer()
           |> delete(~p"/api/v1/agents/#{other_agent.uid}/cron-schedules/#{morning.id}")
           |> json_response(404)

    removed =
      conn
      |> recycle_bearer()
      |> delete(~p"/api/v1/agents/#{agent.uid}/cron-schedules/#{morning.id}")
      |> json_response(200)

    assert get_in(removed, ["cron_schedule", "status"]) == "deleted"

    remaining =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/cron-schedules?agent=#{agent.uid}")
      |> json_response(200)

    assert [%{"id" => remaining_id}] = remaining["cron_schedules"]
    assert remaining_id == evening.id
  end

  test "a malformed cron schedule id answers not found in the console envelope", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    assert %{"error" => %{"code" => "not_found", "message" => message}} =
             conn
             |> recycle_bearer()
             |> get(~p"/api/v1/agents/#{agent.uid}/cron-schedules/not-a-uuid")
             |> json_response(404)

    assert is_binary(message)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> recycle_bearer()
             |> delete(~p"/api/v1/agents/#{agent.uid}/cron-schedules/not-a-uuid")
             |> json_response(404)
  end

  test "creation carries the owner conversation and update accepts multiple targets",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    api_spec = AnkoleWeb.APISpec.spec()
    conn = bearer_conn(conn)

    created =
      conn
      |> post(~p"/api/v1/agents/#{agent.uid}/cron-schedules", cron_body("session-a", "digest"))
      |> json_response(200)

    assert_schema(created, "ScheduleCronScheduleResponse", api_spec)
    assert get_in(created, ["cron_schedule", "owner_session_id"]) == "session-a"

    assert get_in(created, ["cron_schedule", "execution_session_id"]) ==
             "cron:" <> get_in(created, ["cron_schedule", "id"])

    assert get_in(created, ["cron_schedule", "status"]) == "active"

    assert get_in(created, ["cron_schedule", "delivery", "targets"]) == [
             %{
               "binding_name" => "lark",
               "signal_channel_id" => "lark:chat:digest"
             }
           ]

    schedule_id = get_in(created, ["cron_schedule", "id"])

    targets = [
      %{"binding_name" => "lark", "signal_channel_id" => "lark:chat:digest"},
      %{"binding_name" => "lark-record", "signal_channel_id" => "lark:chat:archive"}
    ]

    updated =
      conn
      |> recycle_bearer()
      |> patch(~p"/api/v1/agents/#{agent.uid}/cron-schedules/#{schedule_id}", %{
        "delivery" => %{"targets" => targets}
      })
      |> json_response(200)

    assert get_in(updated, ["cron_schedule", "delivery", "targets"]) == targets

    assert conn
           |> recycle_bearer()
           |> post(
             ~p"/api/v1/agents/#{agent.uid}/cron-schedules",
             Map.delete(cron_body("session-a", "second-digest"), "owner_session_id")
           )
           |> json_response(422)

    assert conn
           |> recycle_bearer()
           |> post(
             ~p"/api/v1/agents/#{agent.uid}/cron-schedules",
             Map.put(cron_body("session-a", "third-digest"), "payload", %{})
           )
           |> json_response(422)
  end

  test "admin lists and cancels checkbacks across every session of one agent", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = checkback!(agent.uid, "session-a", "check the build")
    second = checkback!(agent.uid, "session-b", "check the deploy")
    foreign = checkback!(other_agent.uid, "session-c", "check the backup")

    api_spec = AnkoleWeb.APISpec.spec()
    conn = bearer_conn(conn)

    everything =
      conn
      |> get(~p"/api/v1/checkbacks")
      |> json_response(200)

    assert MapSet.new(everything["schedule_events"], & &1["id"]) ==
             MapSet.new([first.id, second.id, foreign.id])

    list =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/checkbacks?agent=#{agent.uid}")
      |> json_response(200)

    assert_schema(list, "ScheduleEventListResponse", api_spec)
    assert %{"schedule_events" => events} = list
    assert MapSet.new(events, & &1["id"]) == MapSet.new([first.id, second.id])
    assert MapSet.new(events, & &1["session_id"]) == MapSet.new(["session-a", "session-b"])

    assert conn
           |> recycle_bearer()
           |> delete(~p"/api/v1/agents/#{other_agent.uid}/checkbacks/#{first.id}")
           |> json_response(404)

    cancelled =
      conn
      |> recycle_bearer()
      |> delete(~p"/api/v1/agents/#{agent.uid}/checkbacks/#{first.id}")
      |> json_response(200)

    assert get_in(cancelled, ["schedule_event", "status"]) == "cancelled"
  end

  test "missing bearer token is rejected", %{conn: conn} do
    assert conn
           |> get(~p"/api/v1/cron-schedules")
           |> json_response(401)
  end

  defp cron_body(owner_session_id, name) do
    %{
      "owner_session_id" => owner_session_id,
      "binding_name" => "lark",
      "name" => name,
      "schedule" => %{"kind" => "cron", "expression" => "0 9 * * *"},
      "timezone" => "Asia/Shanghai",
      "payload" => %{"task" => "console test task for #{name}"},
      "delivery" => %{
        "targets" => [
          %{"binding_name" => "lark", "signal_channel_id" => "lark:chat:#{name}"}
        ]
      },
      "idempotency_key" => "console-test-#{name}"
    }
  end

  defp cron_schedule!(agent_uid, owner_session_id, name) do
    attrs =
      owner_session_id
      |> cron_body(name)
      |> Map.put("agent_uid", agent_uid)

    assert {:ok, %{cron_schedule: schedule}} = Schedule.create_cron_schedule(attrs)
    schedule
  end

  defp checkback!(agent_uid, session_id, reason) do
    assert {:ok, %{scheduled_event: event}} =
             Schedule.create_check_back_later(%{
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
               "reply_route" => %{"signal_channel_id" => "lark:chat:#{session_id}"}
             })

    event
  end

  defp recycle_bearer(conn) do
    authorization = get_req_header(conn, "authorization") |> List.first()

    conn
    |> recycle()
    |> put_req_header("authorization", authorization)
    |> put_req_header("content-type", "application/json")
  end
end
