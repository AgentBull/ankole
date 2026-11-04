defmodule AnkoleWeb.JSONAPI.AutomationJobsTest do
  use AnkoleWeb.ConnCase, async: false
  import Ecto.Query
  import Ankole.PrincipalsFixtures
  alias Ankole.{AutomationJobs, Repo}

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = Ankole.Setup.Config.delete_bootstrap_activation_code()
    :ok
  end

  test "Console inspects Page Jobs and their results directly by Job ID", %{conn: conn} do
    human = human_fixture().principal

    job =
      Ankole.WorkFixtures.applet_job(human.uid, %{
        label: "Console Action",
        authorization_kind: "human"
      })

    other = Ankole.WorkFixtures.applet_job(human.uid)

    {:ok, %{automation_job_run: queued}} =
      Repo.transact(fn ->
        Ankole.WorkFixtures.dispatch_job_in_tx(job, %{
          "id" => "console",
          "type" => "manual",
          "data" => %{}
        })
      end)

    assert {:ok, %{run: running}} = AutomationJobs.start_applet_attempt(queued.id, 0)

    assert {:ok, _} =
             AutomationJobs.finish_attempt(running.id, running.attempt_id, %{
               status: "succeeded",
               result: %{"checked" => true},
               stdout: "Synced 3 rows.\n",
               stderr: "Provider warning.\n",
               stdout_truncated: true
             })

    conn = console_conn(conn)
    list = conn |> request("/api/v2/automation-jobs") |> json_response(200)

    assert MapSet.new(list["data"], & &1["id"]) ==
             MapSet.new([to_string(job.id), to_string(other.id)])

    detail = conn |> request("/api/v2/automation-jobs/#{job.id}") |> json_response(200)
    assert detail["data"]["attributes"]["page_id"] == job.page_id
    assert detail["data"]["attributes"]["action_key"] == "work"
    assert detail["data"]["attributes"]["human_uid"] == human.uid
    refute Map.has_key?(detail["data"]["attributes"], "agent_uid")
    runs = conn |> request("/api/v2/automation-jobs/#{job.id}/runs") |> json_response(200)

    assert [%{"attributes" => %{"status" => "succeeded", "result" => %{"checked" => true}}}] =
             runs["data"]

    attributes = hd(runs["data"])["attributes"]
    assert attributes["event"] == queued.event
    assert attributes["started_at"] == DateTime.to_iso8601(running.started_at)
    assert {:ok, _, 0} = DateTime.from_iso8601(attributes["finished_at"])
    assert attributes["stdout"] == "Synced 3 rows.\n"
    assert attributes["stderr"] == "Provider warning.\n"
    assert attributes["stdout_truncated"] == true
    assert attributes["stderr_truncated"] == false
  end

  test "Job detail requires the tenant-wide Job inspection permission", %{conn: conn} do
    human = human_fixture().principal
    job = Ankole.WorkFixtures.applet_job(human.uid)
    {conn, uid} = console_conn_with_principal(conn)

    for {pattern, status} <- [
          {"site_console:automation_jobs", 200},
          {"site_console:agent:someone:automation_jobs", 403}
        ] do
      Repo.delete_all(
        from g in Ankole.AuthZ.Grant,
          where:
            g.resource_pattern in ["site_console:**", "tenant_console:**"] or
              g.principal_uid == ^uid
      )

      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: uid,
                 resource_pattern: pattern,
                 action: "read",
                 condition: "true",
                 metadata: %{}
               })

      assert conn |> request("/api/v2/automation-jobs/#{job.id}") |> json_response(status)
    end
  end

  test "missing browser session is rejected", %{conn: conn} do
    assert conn |> get("/api/v2/automation-jobs") |> json_response(401)
  end

  defp request(conn, path) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end
end
