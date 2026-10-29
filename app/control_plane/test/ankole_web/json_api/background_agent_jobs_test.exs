defmodule AnkoleWeb.JSONAPI.BackgroundAgentJobsTest do
  @moduledoc "Checks the v2 background Agent Job routes: the list, the record, cancel, and complete."
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query, warn: false
  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]

  alias Ankole.AppConfigure.Registry
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  @media "application/vnd.api+json"

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin lists with filters and pages, reads one Job, and cancels it", %{conn: conn} do
    agent = background_agent_fixture().principal
    other_agent = background_agent_fixture().principal
    oldest = create_job!(agent.uid, "oldest")
    middle = create_job!(agent.uid, "middle")
    newest = create_job!(other_agent.uid, "newest")

    set_queued_at(oldest, ~U[2026-07-10 01:00:00.000000Z])
    set_queued_at(middle, ~U[2026-07-10 02:00:00.000000Z])
    set_queued_at(newest, ~U[2026-07-10 03:00:00.000000Z])

    {conn, admin_uid} = console_conn_with_principal(conn)
    first_page = conn |> send_v2(:get, "/api/v2/background-agent-jobs?page[limit]=2") |> ok()

    assert ids(first_page) == [newest.id, middle.id]

    # A board row stays at what the board draws. The queued prompt, the result,
    # the error, and the metadata grow with the work the job did, and a list page
    # holds up to 100 rows and reloads on a timer.
    assert %{"data" => [%{"type" => "background_agent_job", "attributes" => listed} | _]} =
             first_page

    assert Map.keys(listed) |> Enum.sort() ==
             ~w(agent_uid attempts duration_seconds execution_failures inserted_at status title workspace_template_id)

    assert listed["title"] == newest.title
    assert is_integer(listed["duration_seconds"])

    second_page = conn |> send_v2(:get, next_path(first_page)) |> ok()

    assert ids(second_page) == [oldest.id]
    assert second_page["links"]["next"] == nil

    assert conn
           |> send_v2(
             :get,
             "/api/v2/background-agent-jobs?agent_uid=#{agent.uid}&status=queued"
           )
           |> ok()
           |> ids() == [middle.id, oldest.id]

    assert search_ids(conn, "MIDDLE", agent.uid) == [middle.id]
    assert search_ids(conn, Integer.to_string(oldest.id)) == [oldest.id]

    assert %{"errors" => [_ | _]} =
             conn
             |> send_v2(:get, "/api/v2/background-agent-jobs?status=unrecognized")
             |> json_response(400)

    assert %{"data" => %{"id" => middle_id, "attributes" => detail}} =
             conn |> send_v2(:get, "/api/v2/background-agent-jobs/#{middle.id}") |> ok()

    assert middle_id == Integer.to_string(middle.id)
    assert detail["title"] == middle.title
    assert detail["workspace_template_id"] == nil
    assert detail["continued_from_job_id"] == nil
    assert detail["workspace_owner_job_id"] == middle.id
    assert detail["model_profile"] == "coding"

    cancelled =
      conn
      |> send_v2(:post, "/api/v2/background-agent-jobs/#{middle.id}/cancel")
      |> json_response(201)

    assert cancelled["id"] == middle.id
    assert cancelled["status"] == "stopped"

    assert cancelled["metadata"]["cancel_requested_by"] ==
             to_string(
               Ankole.ActorRef.from_principal(%{uid: admin_uid, tenant_id: Repo.tenant_id!()})
             )

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> send_v2(:post, "/api/v2/background-agent-jobs/1000000/cancel")
             |> json_response(404)
  end

  test "external completion reads its result summary from the JSON:API body", %{conn: conn} do
    agent = background_agent_fixture().principal
    job = create_job!(agent.uid, "external-completion")
    conn = console_conn(conn)

    completed =
      conn
      |> send_v2(:post, "/api/v2/background-agent-jobs/#{job.id}/complete", %{
        "result_summary" => "EXTERNALLY-VERIFIED"
      })
      |> json_response(201)

    assert completed["status"] == "succeeded"
    assert completed["result"]["summary"] == "EXTERNALLY-VERIFIED"

    stopped = create_job!(agent.uid, "stopped-completion")
    {:ok, _} = BackgroundAgentJobs.request_stop(stopped.id, %{"agent_uid" => agent.uid})

    assert %{"errors" => [%{"code" => "background_agent_job_terminal"}]} =
             conn
             |> send_v2(:post, "/api/v2/background-agent-jobs/#{stopped.id}/complete", %{
               "result_summary" => "late"
             })
             |> json_response(409)
  end

  test "title search treats LIKE control characters as ordinary text", %{conn: conn} do
    agent = background_agent_fixture().principal
    percent = create_job!(agent.uid, "literal-percent", "Console percent%marker")
    _percent_wildcard = create_job!(agent.uid, "percent-wildcard", "Console percent-any-marker")
    underscore = create_job!(agent.uid, "literal-underscore", "Console under_marker")
    _underscore_wildcard = create_job!(agent.uid, "underscore-wildcard", "Console underXmarker")
    backslash = create_job!(agent.uid, "literal-backslash", "Console slash\\marker")
    conn = console_conn(conn)

    assert search_ids(conn, "percent%marker") == [percent.id]
    assert search_ids(conn, "under_marker") == [underscore.id]
    assert search_ids(conn, "slash\\marker") == [backslash.id]
  end

  test "keyset pages neither skip nor repeat jobs with the same queued timestamp", %{conn: conn} do
    agent = background_agent_fixture().principal
    jobs = Enum.map(1..3, &create_job!(agent.uid, "same-time-#{&1}"))
    Enum.each(jobs, &set_queued_at(&1, ~U[2026-07-10 04:00:00.000000Z]))
    conn = console_conn(conn)

    pages =
      Enum.scan(1..3, nil, fn
        1, nil -> conn |> send_v2(:get, "/api/v2/background-agent-jobs?page[limit]=1") |> ok()
        _page, previous -> conn |> send_v2(:get, next_path(previous)) |> ok()
      end)

    paged_ids = Enum.flat_map(pages, &ids/1)
    assert List.last(pages)["links"]["next"] == nil

    assert length(Enum.uniq(paged_ids)) == 3
    assert MapSet.new(paged_ids) == MapSet.new(Enum.map(jobs, & &1.id))
  end

  test "the routes require a Console browser session", %{conn: conn} do
    assert conn |> get("/api/v2/background-agent-jobs") |> json_response(401)
  end

  defp send_v2(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media)
    |> put_req_header("content-type", @media)
    |> dispatch(@endpoint, method, path, data && Jason.encode!(%{data: data}))
  end

  defp ok(conn), do: json_response(conn, 200)

  # The next link carries the keyset of the last row of the page.
  defp next_path(%{"links" => %{"next" => next}}) do
    uri = URI.parse(next)
    uri.path <> "?" <> uri.query
  end

  defp ids(%{"data" => rows}), do: Enum.map(rows, &String.to_integer(&1["id"]))

  defp search_ids(conn, search, agent_uid \\ nil) do
    query =
      URI.encode_query(
        Map.reject(%{"search" => search, "agent_uid" => agent_uid}, &is_nil(elem(&1, 1)))
      )

    conn |> send_v2(:get, "/api/v2/background-agent-jobs?#{query}") |> ok() |> ids()
  end

  defp create_job!(agent_uid, suffix, title \\ nil) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
               "agent_uid" => agent_uid,
               "owner_session_id" => "console-parent-#{suffix}",
               "source_tool_call_id" => "console-tool-#{suffix}",
               "title" => title || "Console job #{suffix}",
               "task" => "Complete console job #{suffix}. Keep the result concise.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "conversation_id" =>
                   Ankole.ExternalConversationsFixtures.external_conversation_id(
                     "console-chat-#{suffix}"
                   )
               }
             })

    job
  end

  defp set_queued_at(job, queued_at) do
    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [queued_at: queued_at])
  end
end
