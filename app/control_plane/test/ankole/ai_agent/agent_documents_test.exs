defmodule Ankole.AIAgent.AgentDocumentsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Repo

  test "lists and independently replaces agent documents with optimistic concurrency" do
    %{principal: agent} = agent_fixture()

    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert documents["mission"]["kind"] == "mission"
    assert documents["soul"]["kind"] == "soul"

    assert documents["mission"]["content_hash"] ==
             SourceReader.hash(documents["mission"]["content"])

    original_mission_hash = documents["mission"]["content_hash"]
    original_soul = documents["soul"]

    assert {:ok, mission} =
             Library.replace_agent_document(
               agent.uid,
               "mission",
               "Own the customer-research loop.",
               original_mission_hash
             )

    assert mission == %{
             "kind" => "mission",
             "content" => "Own the customer-research loop.",
             "content_hash" => SourceReader.hash("Own the customer-research loop.")
           }

    assert {:error, :agent_library_document_conflict} =
             Library.replace_agent_document(
               agent.uid,
               "mission",
               "Stale overwrite",
               original_mission_hash
             )

    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert documents["mission"] == mission
    assert documents["soul"] == original_soul

    assert {:ok, empty_soul} =
             Library.replace_agent_document(
               agent.uid,
               "soul",
               "",
               original_soul["content_hash"]
             )

    assert empty_soul["content"] == ""
    assert {:ok, ""} = Library.get_soul(agent.uid)
  end

  test "materializes bundled fallback documents for an agent missing seeded rows" do
    %{principal: agent} = agent_fixture()
    Repo.delete_all(AgentLibraryContainerEntry)

    assert {:ok, documents} = Library.list_agent_documents(agent.uid)

    assert documents["mission"]["content"] ==
             SourceReader.load_default_mission_template()

    assert {:ok, updated} =
             Library.replace_agent_document(
               agent.uid,
               "mission",
               "Materialized mission",
               documents["mission"]["content_hash"]
             )

    assert updated["content"] == "Materialized mission"

    assert %AgentLibraryContainerEntry{source_kind: "mission", content: "Materialized mission"} =
             Repo.get_by!(AgentLibraryContainerEntry,
               agent_uid: agent.uid,
               path: "MISSION.md"
             )
  end

  test "rejects unknown agents, document kinds, and non-text content" do
    assert {:error, :not_found} = Library.list_agent_documents("missing-agent")

    assert {:error, :not_found} =
             Library.replace_agent_document("missing-agent", "mission", "value", "hash")

    %{principal: agent} = agent_fixture()

    assert {:error, :invalid_document_kind} =
             Library.replace_agent_document(agent.uid, "setting", "value", "hash")

    assert {:error, :invalid_agent_document} =
             Library.replace_agent_document(agent.uid, "mission", :not_text, "hash")
  end
end
