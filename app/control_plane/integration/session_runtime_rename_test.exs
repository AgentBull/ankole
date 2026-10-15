defmodule Ankole.SessionRuntimeRenameIntegrationTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals.Principal
  alias Ecto.Adapters.SQL

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag timeout: 180_000
  @default_tenant "019a2b00-0000-7000-8000-000000000001"
  @previous_runtime "Ankole.Conversations"
  @migration 20_261_014_000_100

  test "runtime table and worker renames preserve stored progress, receipts and jobs" do
    config = Ankole.Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(:database, "ankole_session_rename_#{System.unique_integer([:positive])}")
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:log, false)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    {:ok, pid} = UpgradeRepo.start_link(config)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      :ok = Ecto.Adapters.Postgres.storage_down(config)
    end)

    migrations = Path.expand("../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_261_012_000_400, log: false)

    uid = Ankole.Kernel.gen_uuid_v7()

    UpgradeRepo.insert!(%Principal{
      uid: uid,
      tenant_id: @default_tenant,
      type: :agent,
      display_name: "Session rename Agent",
      status: :active,
      access_version: 1
    })

    conversation =
      UpgradeRepo.insert!(%Conversation{
        tenant_id: @default_tenant,
        subject_uid: uid,
        conversation_key: "session-rename"
      })

    messages =
      for iteration <- 1..2 do
        message =
          UpgradeRepo.insert!(%Message{
            tenant_id: @default_tenant,
            subject_uid: uid,
            conversation_id: conversation.id,
            type: "message",
            status: "complete",
            content: [%{"type" => "output_text", "text" => "round #{iteration}"}]
          })

        SQL.query!(UpgradeRepo, """
        INSERT INTO conversation_round_states
          (message_id, tenant_id, iteration, steer_event_ids, nudged, repaired,
           workflow_attempt, truncated_rounds, outcome, pages, results)
        VALUES ('#{message.id}', '#{@default_tenant}', #{iteration},
          ARRAY['#{Ankole.Kernel.gen_uuid_v7()}']::uuid[], true, true, 2, 1, 'sleeping',
          '{"source":{"page_1":"cursor"}}', '{"call":{"value":"committed"}}')
        """)

        SQL.query!(UpgradeRepo, """
        INSERT INTO conversation_tool_receipts
          (response_id, call_id, agent_uid, session_id, result, inserted_at, tenant_id)
        VALUES ('resp_#{message.id}', 'call-#{iteration}', '#{uid}', 'session-rename',
          '{"value":"committed","after_commit":[]}', '2026-10-14 00:00:00', '#{@default_tenant}')
        """)

        message
      end

    for {state, index} <-
          Enum.with_index(
            ~w(available scheduled retryable executing completed cancelled discarded)
          ) do
      worker =
        @previous_runtime <>
          if(rem(index, 2) == 0, do: ".Jobs.EnsureDriver", else: ".Reconciler")

      UpgradeRepo.insert!(%Oban.Job{
        worker: worker,
        queue: "conversations",
        state: state,
        args: %{
          "tenant_id" => @default_tenant,
          "agent_uid" => uid,
          "session_id" => "session-rename"
        },
        attempt: 1,
        max_attempts: 5,
        priority: 2,
        scheduled_at: ~U[2026-10-15 00:00:00.000000Z],
        tags: ["rename"]
      })
    end

    for worker <- [
          "Ankole.SignalsGateway.Delivery.Jobs.Dispatch",
          @previous_runtime <> "Extra.Jobs.EnsureDriver"
        ] do
      UpgradeRepo.insert!(%Oban.Job{worker: worker, queue: "default", args: %{"keep" => true}})
    end

    rounds = table_rows("conversation_round_states")
    receipts = table_rows("conversation_tool_receipts")
    jobs = table_rows("oban_jobs")
    constraints = constraints("conversation_round_states", "conversation_tool_receipts")
    indexes = indexes("conversation_round_states", "conversation_tool_receipts")
    assert length(rounds) == 2
    assert length(receipts) == 2

    assert Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    assert table_rows("session_round_states") == rounds
    assert table_rows("session_tool_receipts") == receipts

    assert constraints("session_round_states", "session_tool_receipts") ==
             renamed_catalog(constraints)

    assert indexes("session_round_states", "session_tool_receipts") == renamed_catalog(indexes)

    assert [[nil, nil]] =
             SQL.query!(UpgradeRepo, """
             SELECT to_regclass('conversation_round_states'), to_regclass('conversation_tool_receipts')
             """).rows

    migrated_jobs = table_rows("oban_jobs")

    assert migrated_jobs ==
             Enum.map(jobs, fn job ->
               if String.starts_with?(job["worker"], @previous_runtime <> ".") do
                 %{
                   job
                   | "worker" =>
                       String.replace_prefix(job["worker"], @previous_runtime, "Ankole.Sessions")
                 }
               else
                 job
               end
             end)

    for job <- migrated_jobs, String.starts_with?(job["worker"], "Ankole.Sessions.") do
      assert {:ok, worker} = Oban.Worker.from_string(job["worker"])
      assert worker in [Ankole.Sessions.Jobs.EnsureDriver, Ankole.Sessions.Reconciler]
    end

    assert_constraint(
      "UPDATE session_round_states SET outcome = 'invalid'",
      :check_violation,
      "session_round_states_outcome"
    )

    assert_constraint(
      "UPDATE session_tool_receipts SET result = '[]'::jsonb",
      :check_violation,
      "session_tool_receipts_result_object"
    )

    assert_constraint(
      "INSERT INTO session_tool_receipts SELECT * FROM session_tool_receipts",
      :unique_violation,
      "session_tool_receipts_pkey"
    )

    assert_constraint(
      "UPDATE session_round_states SET message_id = '#{Ankole.Kernel.gen_uuid_v7()}' WHERE message_id = '#{hd(messages).id}'",
      :foreign_key_violation,
      "session_round_states_message_id_fkey"
    )

    assert_constraint(
      "UPDATE session_tool_receipts SET agent_uid = '#{Ankole.Kernel.gen_uuid_v7()}'",
      :foreign_key_violation,
      "session_tool_receipts_agent_uid_fkey"
    )

    UpgradeRepo.delete!(hd(messages))
    assert length(table_rows("session_round_states")) == 1
    assert length(table_rows("session_tool_receipts")) == 2
    UpgradeRepo.delete!(UpgradeRepo.get!(Principal, uid))
    assert table_rows("session_round_states") == []
    assert table_rows("session_tool_receipts") == []
    assert table_rows("oban_jobs") == migrated_jobs
    assert Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: @migration, log: false) == []
  end

  defp table_rows(table) do
    SQL.query!(
      UpgradeRepo,
      "SELECT to_jsonb(record) FROM #{table} AS record ORDER BY to_jsonb(record)->>'id'"
    ).rows
    |> Enum.map(fn [row] -> row end)
    |> Enum.sort()
  end

  defp constraints(rounds, receipts) do
    SQL.query!(UpgradeRepo, """
    SELECT oid, conname, to_jsonb(record) - 'conname'
    FROM pg_constraint AS record
    WHERE conrelid IN ('#{rounds}'::regclass, '#{receipts}'::regclass)
    ORDER BY oid
    """).rows
  end

  defp indexes(rounds, receipts) do
    SQL.query!(UpgradeRepo, """
    SELECT indexrelid, relation.relname, to_jsonb(record)
    FROM pg_index AS record JOIN pg_class AS relation ON relation.oid = indexrelid
    WHERE indrelid IN ('#{rounds}'::regclass, '#{receipts}'::regclass)
    ORDER BY indexrelid
    """).rows
  end

  defp renamed_catalog(rows) do
    Enum.map(rows, fn [oid, name, definition] ->
      [oid, String.replace_prefix(name, "conversation_", "session_"), definition]
    end)
  end

  defp assert_constraint(sql, code, name) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code, constraint: ^name}}} =
             SQL.query(UpgradeRepo, sql)
  end
end
