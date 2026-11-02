defmodule Ankole.Repo.Migrations.UnifyAgentContracts do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE agent_skills DROP CONSTRAINT agent_skills_source_kind_check")

    execute(
      "ALTER TABLE agent_skills ADD CONSTRAINT agent_skills_source_kind_check CHECK (source_kind IN ('builtin', 'shared', 'installed'))"
    )

    flush()

    for [tenant_id] <- repo().query!("SELECT id::text FROM tenants").rows do
      Ankole.Repo.with_tenant(tenant_id, fn -> migrate_tenant(tenant_id) end)
    end

    drop(table(:agent_library_container_entries))
  end

  defp migrate_tenant(tenant_id) do
    alias Ankole.AIAgent.Library.{Contracts, Knowledge, SourceReader}
    :ok = Contracts.initialize_in_tx()

    defaults = %{
      "SOUL.md" => SourceReader.load_default_soul_template(),
      "MISSION.md" => SourceReader.load_default_mission_template(),
      "DESIGN.md" => SourceReader.load_default_design_template(),
      "ConfidentialityPolicy.md" => SourceReader.load_default_confidentiality_policy_template()
    }

    for [uid, type] <-
          repo().query!("SELECT uid, type FROM agents WHERE tenant_id = $1::uuid ORDER BY uid", [
            Ecto.UUID.dump!(tenant_id)
          ]).rows do
      type =
        case type do
          "ai_colleague" -> :ai_colleague
          "personal_assistant" -> :personal_assistant
        end

      :ok = Contracts.seed_agent_in_tx(uid, type)
      {:ok, namespace} = Knowledge.ensure_namespace_in_tx()
      {:ok, agent} = Knowledge.child(namespace.agents.id, uid)

      rows =
        repo().query!(
          "SELECT path, content FROM agent_library_container_entries WHERE tenant_id = $1::uuid AND agent_uid = $2 AND deleted_at IS NULL",
          [Ecto.UUID.dump!(tenant_id), uid]
        ).rows

      documents = Map.merge(defaults, Map.new(rows, fn [path, content] -> {path, content} end))

      customized =
        Enum.any?(
          ~w(SOUL.md MISSION.md ConfidentialityPolicy.md),
          &(documents[&1] != defaults[&1])
        )

      if type == :personal_assistant or customized do
        confidentiality =
          if documents["ConfidentialityPolicy.md"] == defaults["ConfidentialityPolicy.md"],
            do: "",
            else: documents["ConfidentialityPolicy.md"]

        content =
          [documents["SOUL.md"], documents["MISSION.md"], confidentiality]
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.join("\n\n")

        {:ok, node} = Knowledge.ensure_child_in_tx(agent.id, "AGENTS.override.md", :knowledge)
        {:ok, _} = Knowledge.put_markdown_in_tx(node, content)
      end

      if documents["DESIGN.md"] != defaults["DESIGN.md"] do
        {:ok, node} = Knowledge.ensure_child_in_tx(agent.id, "DESIGN.override.md", :knowledge)
        {:ok, _} = Knowledge.put_markdown_in_tx(node, documents["DESIGN.md"])
      end
    end
  end

  def down,
    do:
      raise(
        "Agent contracts live on Pod pages; restore a database backup to reverse this migration"
      )
end
