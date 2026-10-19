defmodule Ankole.Pod.GitHubSyncIntegrationTest do
  @moduledoc "Live read-only GitHub API through the sync owner of an active AutomationJob attempt."
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  @moduletag :external
  @moduletag timeout: 90_000

  alias Ankole.Pod.{Database, DbRecord, DbSyncBinding, DbTable, RPCBroker}
  alias Ankole.RuntimeFabric.V1, as: FabricProto

  @repository "octocat/Hello-World"

  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    Ankole.AppConfigure.Cache.clear_for_test()
    ctx = Ankole.PodSyncFixtures.binding_attempt_fixture(@repository)

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        Ankole.AutomationJobs.finish_attempt(ctx.run.id, ctx.run.attempt_id, %{
          "status" => "failed",
          "error" => "provider integration cleanup"
        })

        :ok = Ankole.PrincipalsFixtures.delete_agent_fixture_rows(ctx.agent)
        {:ok, tenant} = Ankole.Tenants.get(tenant.id)
        {:ok, _} = Ankole.Tenants.delete(tenant)

        result =
          Enum.reduce_while(1..200, :pending, fn _, _ ->
            case Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => tenant.id}}) do
              :ok -> {:halt, :ok}
              {:snooze, _} -> {:cont, :pending}
            end
          end)

        assert result == :ok
      end)
    end)

    ctx
  end

  test "real issue IDs deduplicate through the current AutomationJob attempt, preserving local fields and atomic cursor",
       ctx do
    response =
      Req.get!("https://api.github.com/repos/#{@repository}/issues",
        params: [state: "all", sort: "created", direction: "asc", per_page: 10],
        headers: [
          {"accept", "application/vnd.github+json"},
          {"user-agent", "Ankole Pod provider integration"},
          {"x-github-api-version", "2026-03-10"}
        ],
        retry: false,
        receive_timeout: 30_000,
        connect_options: [timeout: 10_000]
      )

    assert response.status == 200, "GitHub read failed: HTTP #{response.status}"
    assert is_list(response.body)
    assert [request_id] = Req.Response.get_header(response, "x-github-request-id")
    issues = response.body |> Enum.reject(&Map.has_key?(&1, "pull_request")) |> Enum.take(3)
    assert issues != []

    rows =
      Enum.map(issues, fn issue ->
        assert is_integer(issue["id"]) and is_binary(issue["title"])
        %{external_id: Integer.to_string(issue["id"]), data: %{"title" => issue["title"]}}
      end)

    cursor = %{
      "repository" => @repository,
      "page" => 2,
      "etag" => List.first(Req.Response.get_header(response, "etag"))
    }

    IO.puts(
      "GitHub provider integration: repository=#{@repository} request_id=#{request_id} issue_ids=#{Enum.map_join(rows, ",", & &1.external_id)}"
    )

    assert {:ok, %{"result" => %{changed_ids: changed}}} = submit(ctx, rows, cursor)
    assert length(changed) == length(rows)
    assert Repo.get!(DbSyncBinding, ctx.binding.id).cursor == cursor

    first = Repo.get_by!(DbRecord, table_id: ctx.table.id, external_id: hd(rows).external_id)

    assert {:ok, _} =
             Database.write_records(ctx.human, ctx.table.id, %{
               updates: [%{id: first.id, data: %{ctx.local.id => "High"}, expected_versions: %{}}]
             })

    assert {:ok, %{"result" => %{changed_ids: repeated}}} = submit(ctx, rows, cursor)
    assert MapSet.new(repeated) == MapSet.new(changed)
    assert Repo.aggregate(DbRecord, :count) == length(rows)
    record = Repo.get_by!(DbRecord, table_id: ctx.table.id, external_id: hd(rows).external_id)
    assert record.id == first.id
    assert record.data[ctx.local.id] == "High"
    assert record.data[ctx.title.id] == hd(rows).data["title"]

    assert {:error, :synced_field_readonly} =
             Database.write_records(ctx.human, ctx.table.id, %{
               updates: [
                 %{
                   id: record.id,
                   data: %{ctx.title.id => "Local overwrite"},
                   expected_versions: %{ctx.title.id => record.versions[ctx.title.id]}
                 }
               ]
             })

    before = records(ctx.table.id)
    before_version = Repo.get!(DbTable, ctx.table.id).data_version
    invalid_cursor_rows = Enum.map(rows, &put_in(&1, [:data, "title"], "must roll back"))

    assert {:error, %{"code" => "invalid_sync_cursor"}} =
             submit(ctx, invalid_cursor_rows, "invalid")

    assert records(ctx.table.id) == before
    assert Repo.get!(DbSyncBinding, ctx.binding.id).cursor == cursor
    assert Repo.get!(DbTable, ctx.table.id).data_version == before_version

    assert {:ok, %{status: "succeeded"}} =
             Ankole.AutomationJobs.finish_attempt(ctx.run.id, ctx.run.attempt_id, %{
               "status" => "succeeded",
               "exit_code" => 0
             })
  end

  defp submit(ctx, rows, cursor) do
    route = "github-sync-#{System.unique_integer([:positive])}"
    Ankole.WorkerFilesFake.start!(route, files: %{"records.json" => Torque.encode!(rows)})

    RPCBroker.handle_sync(
      ctx.agent,
      %FabricProto.PodSyncRequest{
        binding_id: ctx.binding.id,
        automation_job_run_id: Integer.to_string(ctx.run.id),
        attempt_id: ctx.run.attempt_id,
        records_home_relative_path: "records.json",
        cursor_json: Torque.encode!(cursor)
      },
      %{request_id: "github-provider-integration", worker_id: ctx.agent, route: route}
    )
  end

  defp records(table_id) do
    Repo.all(from record in DbRecord, where: record.table_id == ^table_id, order_by: record.id)
    |> Enum.map(&Map.take(&1, [:id, :external_id, :data, :versions, :updated_at]))
  end
end
