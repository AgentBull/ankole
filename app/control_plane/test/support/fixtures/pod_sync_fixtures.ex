defmodule Ankole.PodSyncFixtures do
  @moduledoc false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  alias Ankole.{AutomationJobs, Repo}
  alias Ankole.Pod.{Database, Pages, Sync}

  @limits %{
    "local_rows" => 5000,
    "local_bytes" => 5_000_000,
    "query_rows" => 1000,
    "record_bytes" => 1_000_000,
    "group_count" => 1000,
    "statement_timeout_ms" => 5000
  }

  def binding_attempt_fixture(repository \\ "example/project") do
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.database.limits", @limits)
    human = human_fixture().principal
    agent = agent_fixture().principal
    {:ok, page} = Pages.create(human.uid, %{title: "GitHub issues", type: "database"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(human.uid, page.id, %{
        grants: [%{principal_uid: agent.uid, role: "edit"}]
      })

    {:ok, table} = Database.create_table(agent.uid, page.id, %{name: "Issues"})
    title = Database.fields(table.id) |> Enum.find(& &1.is_primary)

    {:ok, local} =
      Database.create_field(agent.uid, table.id, %{name: "Priority judgment", type: "text"})

    source = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    drive_file_fixture(agent.uid, "automation/github/main.ts")

    {:ok, job} =
      AutomationJobs.create_job(%{
        agent_uid: agent.uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        source_provenance: %{"kind" => "test"},
        reply_route: %{},
        drive_prefix: "automation/github",
        label: "GitHub issue sync",
        wake_on_failure: false
      })

    {:ok, binding} =
      Sync.create(agent.uid, table.id, %{
        connector: "github_issues",
        source: %{"repository" => repository},
        field_map: %{"title" => title.id},
        automation_job_id: job.id
      })

    {:ok, %{automation_job_run: run}} =
      Repo.transact(fn repo ->
        AutomationJobs.enqueue_run_in_tx(repo, job.id, agent.uid, %{
          "specversion" => "1.0",
          "id" => "sync-test",
          "source" => "test://github",
          "type" => "test.triggered",
          "data" => %{}
        })
      end)

    {:ok, %{run: run}} = AutomationJobs.start_attempt(run.id)

    %{
      human: human.uid,
      agent: agent.uid,
      page: page,
      table: table,
      title: title,
      local: local,
      binding: binding,
      job: job,
      run: run
    }
  end
end
