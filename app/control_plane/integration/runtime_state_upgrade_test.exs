defmodule Ankole.RuntimeStateUpgradeIntegrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Ankole.AIGateway.HostedTools.Brain
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Crypto
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AuthZ.Grant
  alias Ankole.Sessions.RoundState
  alias Ankole.AgentWorkers.WorkerEnv.SiteEnvVar

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag timeout: 180_000
  @default_tenant "019a2b00-0000-7000-8000-000000000001"

  test "the stored 2.0 form upgrades without losing raw input, grants or encrypted values" do
    config = Ankole.Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(:database, "ankole_runtime_upgrade_#{System.unique_integer([:positive])}")
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
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_261_011_120_000, log: false)

    uid = Ankole.Kernel.gen_uuid_v7()

    UpgradeRepo.insert_all("principals", [
      %{
        uid: uid,
        tenant_id: Ecto.UUID.dump!(@default_tenant),
        type: "human",
        status: "active",
        access_version: 1,
        inserted_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
    ])

    conversation =
      insert_legacy("ai_gateway_conversations", %{
        tenant_id: @default_tenant,
        subject_uid: uid,
        conversation_key: "upgrade"
      })

    pack = message("Recalled context")
    original = message("中文原文 memory: concepts/source must stay")
    block = "<agent_environment_info>\nmemory: concepts/source\n</agent_environment_info>"

    injected =
      Map.update!(original, "content", &[%{"type" => "input_text", "text" => block} | &1])

    legacy =
      insert_legacy("ai_gateway_messages", %{
        tenant_id: @default_tenant,
        subject_uid: uid,
        conversation_id: conversation.id,
        type: :message,
        status: :complete,
        content: [message("Earlier caller input"), pack, injected],
        metadata: %{
          "request_item_count" => 3,
          "request_metadata" => %{
            "custom" => "kept",
            "model_profile" => "primary",
            "loop" => %{
              "iteration" => 3,
              "outcome" => "sleeping",
              "pages" => %{"source" => %{"page_1" => "cursor"}}
            }
          },
          "brain_injection" => %{
            "items" => [1],
            "environment" => %{
              "item_index" => 2,
              "part_index" => 0,
              "offset" => 0,
              "length" => byte_size(block)
            }
          }
        }
      })

    agent_uid = Ankole.Kernel.gen_uuid_v7()

    UpgradeRepo.insert_all("principals", [
      %{
        uid: agent_uid,
        tenant_id: Ecto.UUID.dump!(@default_tenant),
        type: "agent",
        display_name: "Legacy Agent",
        status: "active",
        access_version: 1,
        inserted_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
    ])

    agent_conversation =
      insert_legacy("ai_gateway_conversations", %{
        tenant_id: @default_tenant,
        subject_uid: agent_uid,
        conversation_key: "legacy-agent",
        metadata: %{
          "brain_context_pack_at" => "2026-10-11T12:00:00Z",
          "brain_context_pack_event" => Ankole.Kernel.gen_uuid_v7()
        }
      })

    legacy_agent =
      insert_legacy("ai_gateway_messages", %{
        tenant_id: @default_tenant,
        subject_uid: agent_uid,
        conversation_id: agent_conversation.id,
        type: :message,
        status: :complete,
        content: [pack, original],
        metadata: %{"request_item_count" => 2}
      })

    assert {:ok, cipher} = Crypto.seal(%{"value" => "site secret"}, "global", "__test.upgrade")
    envelope = %{"type" => "cipher", "value" => cipher}

    UpgradeRepo.insert_all("app_configurations", [
      %{
        scope: "global",
        key: "__test.upgrade",
        value: envelope,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    UpgradeRepo.insert_all("app_configurations", [
      %{
        tenant_id: Ecto.UUID.dump!(@default_tenant),
        scope: "tenant:" <> @default_tenant,
        key: "__test.upgrade",
        value: %{"type" => "plaintext", "value" => "tenant value"},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    assert {:ok, env_cipher} =
             Ankole.SecretKeyBase.seal("shell secret", "worker_env", ["global", "UPGRADE_SECRET"])

    UpgradeRepo.insert_all("agent_computer_worker_envs", [
      %{
        scope: "global",
        name: "UPGRADE_SECRET",
        value: env_cipher,
        secret: true,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    for resource <- ["agent_computer_workers:*", "agent_workers:*", "agentXcomputer_workers:*"] do
      UpgradeRepo.insert_all("permission_grants", [
        %{
          id: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate()),
          tenant_id: Ecto.UUID.dump!(@default_tenant),
          principal_uid: uid,
          resource_pattern: resource,
          action: "read",
          condition: "true",
          metadata: %{},
          inserted_at: DateTime.utc_now(:microsecond),
          updated_at: DateTime.utc_now(:microsecond)
        }
      ])
    end

    pending =
      for {:down, version, _name} <- Ecto.Migrator.migrations(UpgradeRepo, migrations),
          do: version

    assert pending != []
    assert Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false) == pending
    stored = UpgradeRepo.get!(Message, legacy.id)
    assert stored.content == [message("Earlier caller input"), original]
    assert stored.metadata["request_item_count"] == 2
    assert stored.metadata["request_metadata"] == %{"custom" => "kept"}
    assert stored.metadata["model_profile"] == "primary"

    assert Brain.replay(stored.content, stored.metadata) == [
             message("Earlier caller input"),
             pack,
             injected
           ]

    upgraded_agent = UpgradeRepo.get!(Message, legacy_agent.id)
    assert upgraded_agent.content == legacy_agent.content
    assert upgraded_agent.metadata["brain_context_pack_claimed"] == true
    assert Brain.replay(upgraded_agent.content, upgraded_agent.metadata) == [pack, original]
    refute Map.has_key?(upgraded_agent.metadata, "brain_context_pack")
    assert UpgradeRepo.get!(Conversation, agent_conversation.id).metadata == %{}
    state = UpgradeRepo.get!(RoundState, legacy.id)

    assert {state.iteration, state.outcome, state.pages} ==
             {3, :sleeping, %{"source" => %{"page_1" => "cursor"}}}

    assert UpgradeRepo.get_by!(SiteConfig, key: "__test.upgrade").value == envelope
    assert {:ok, %{"value" => "site secret"}} = Crypto.unseal(cipher, "global", "__test.upgrade")
    assert UpgradeRepo.get_by!(SiteEnvVar, name: "UPGRADE_SECRET").value == env_cipher

    assert {:ok, "shell secret"} =
             Ankole.SecretKeyBase.unseal(env_cipher, "worker_env", ["global", "UPGRADE_SECRET"])

    assert [%{tenant_id: @default_tenant}] = UpgradeRepo.all(AppConfig)

    assert Enum.sort(
             UpgradeRepo.all(
               from grant in Grant,
                 where: grant.principal_uid == ^uid,
                 select: grant.resource_pattern
             )
           ) == ["agentXcomputer_workers:*", "agent_workers:*"]

    assert Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false) == []
  end

  defp message(text),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }

  defp insert_legacy(table, attrs) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      Map.merge(
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          metadata: %{},
          inserted_at: now,
          updated_at: now
        },
        attrs
      )

    row =
      Enum.reduce([:id, :tenant_id, :conversation_id], attrs, fn key, row ->
        if Map.has_key?(row, key), do: Map.update!(row, key, &Ecto.UUID.dump!/1), else: row
      end)

    row =
      Enum.reduce([:type, :status], row, fn key, row ->
        if Map.has_key?(row, key), do: Map.update!(row, key, &Atom.to_string/1), else: row
      end)

    {1, nil} = UpgradeRepo.insert_all(table, [row])
    attrs
  end
end
