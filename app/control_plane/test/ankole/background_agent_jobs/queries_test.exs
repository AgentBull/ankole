defmodule Ankole.BackgroundAgentJobs.QueriesTest do
  @moduledoc """
  Compares the Job list read actions with the Ecto list queries that they
  replace: the same fixture gives the same id order, and each page continues
  after the last row of the page before it.
  """
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @base ~U[2026-10-01 00:00:00.000000Z]

  setup do
    %{principal: agent} = background_agent_fixture()
    %{principal: other} = background_agent_fixture()

    # Two Jobs share one queue time, so the id breaks the tie.
    specs = [
      {agent, "Deploy report", :queued, 0},
      {agent, "deploy check", :running, 0},
      {agent, "Weekly digest", :succeeded, 60},
      {other, "Deploy rollback", :failed, 120},
      {agent, "Cleanup 100%_files", :waiting_on_user, 180},
      {other, "Archive", :stopped, 240},
      {agent, "deploy again", :queued, 300},
      {agent, "Cleanup 100 files", :stopped, 360}
    ]

    ids =
      for {{principal, title, status, offset}, index} <- Enum.with_index(specs) do
        job = create_job!(principal.uid, "queries-#{index}")
        queued_at = DateTime.add(@base, offset, :second)

        {1, _} =
          Job
          |> where([job], job.id == ^job.id)
          |> Repo.update_all(
            set: [
              title: title,
              status: status,
              queued_at: queued_at,
              updated_at: DateTime.add(@base, rem(index * 7, 5), :second)
            ]
          )

        job.id
      end

    %{agent: agent, other: other, ids: ids}
  end

  test "the console list gives the old order and continues each page after the last row",
       %{agent: agent, ids: ids} do
    searched_id = Enum.at(ids, 5)

    for opts <- [
          [],
          [status: "queued"],
          [status: "stopped"],
          [agent_uid: agent.uid],
          [search: "deploy"],
          [search: "100%_"],
          [search: Integer.to_string(searched_id)],
          [agent_uid: agent.uid, search: "cleanup"]
        ],
        limit <- [1, 2, 3, 100] do
      assert console_pages(opts, limit) == old_console_ids(opts), inspect({opts, limit})
    end

    assert {:ok, %{jobs: jobs}} = Queries.list_for_console(limit: 100)
    assert [%Job{} | _] = jobs
    assert Enum.all?(jobs, &match?(%Ash.NotLoaded{}, &1.error_code))
  end

  test "the activity list reads only live Jobs with their error projection",
       %{agent: agent} do
    assert {:ok, %{jobs: jobs, next_cursor: nil}} =
             Queries.list_activity(agent.uid, limit: 100)

    assert Enum.map(jobs, & &1.id) ==
             old_console_ids(agent_uid: agent.uid, statuses: Job.live_statuses())

    assert Enum.all?(jobs, &(&1.resource_kind == "background_job"))
    assert Enum.all?(jobs, &Map.has_key?(&1, :error_summary))
  end

  test "the agent list gives the old order for each status group", %{agent: agent} do
    for {status, statuses} <- [
          {"live", Job.live_statuses()},
          {"stop", Job.terminal_statuses()}
        ] do
      expected =
        Job
        |> where([job], job.agent_uid == ^agent.uid and job.status in ^statuses)
        |> order_by([job], desc: job.updated_at, desc: job.id)
        |> select([job], job.id)
        |> Repo.all()

      assert {:ok, %{jobs: jobs, next_cursor: nil}} =
               BackgroundAgentJobs.list_for_agent(agent.uid, status: status)

      assert Enum.map(jobs, & &1.job_id) == expected
    end
  end

  test "a cursor belongs to its list and its parameters", %{agent: agent} do
    assert {:ok, %{next_cursor: console_cursor}} =
             Queries.list_for_console(limit: 1)

    assert is_binary(console_cursor)

    for cursor <- [console_cursor, "not-a-cursor", Base.url_encode64("2|live|")] do
      assert {:error, :invalid_background_agent_job_cursor} =
               BackgroundAgentJobs.list_for_agent(agent.uid, cursor: cursor)
    end

    assert {:error, :invalid_background_agent_job_cursor} =
             Queries.list_for_console(cursor: "not-a-cursor")

    # A cursor of the old format no longer reads a page.
    old_cursor = Base.url_encode64("#{DateTime.to_iso8601(@base)}|1", padding: false)

    assert {:error, :invalid_background_agent_job_cursor} =
             Queries.list_for_console(cursor: old_cursor)
  end

  test "the owner session read gives the live Job ids in id order", %{agent: agent, ids: ids} do
    sessions = Enum.map(0..7, &"parent-session-queries-#{&1}")

    expected =
      Job
      |> where(
        [job],
        job.agent_uid == ^agent.uid and job.owner_session_id in ^sessions and
          job.status in ^Job.live_statuses()
      )
      |> order_by([job], asc: job.id)
      |> select([job], job.id)
      |> Repo.all()

    assert BackgroundAgentJobs.live_job_ids_for_owner_sessions(sessions, agent.uid) == expected
    assert expected != [] and Enum.all?(expected, &(&1 in ids))
  end

  defp console_pages(opts, limit, cursor \\ nil, acc \\ []) do
    assert {:ok, %{jobs: jobs, next_cursor: next}} =
             Queries.list_for_console(
               Keyword.merge(opts, limit: limit, cursor: cursor)
             )

    ids = acc ++ Enum.map(jobs, & &1.id)

    if next do
      assert length(jobs) == limit
      console_pages(opts, limit, next, ids)
    else
      assert length(jobs) <= limit
      ids
    end
  end

  # The Ecto list query that the console list read action replaces.
  defp old_console_ids(opts) do
    Job
    |> then(fn query ->
      if uid = opts[:agent_uid], do: where(query, [job], job.agent_uid == ^uid), else: query
    end)
    |> then(fn query ->
      case opts[:status] do
        nil -> query
        status -> where(query, [job], job.status == ^String.to_existing_atom(status))
      end
    end)
    |> then(fn query ->
      if statuses = opts[:statuses],
        do: where(query, [job], job.status in ^statuses),
        else: query
    end)
    |> then(fn query ->
      case opts[:search] do
        nil ->
          query

        search ->
          pattern = "%#{Repo.escape_like(search)}%"

          case Ankole.ModelIntegerID.parse(search) do
            {:ok, id} -> where(query, [job], job.id == ^id or ilike(job.title, ^pattern))
            _text -> where(query, [job], ilike(job.title, ^pattern))
          end
      end
    end)
    |> order_by([job], desc: job.queued_at, desc: job.id)
    |> select([job], job.id)
    |> Repo.all()
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
               "agent_uid" => agent_uid,
               "owner_session_id" => "parent-session-#{suffix}",
               "source_tool_call_id" => "tool-#{suffix}",
               "title" => "Job #{suffix}",
               "task" => "Complete the #{suffix} job.",
               "reply_route" => %{"binding_name" => "bot"}
             })

    job
  end
end
