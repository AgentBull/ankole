defmodule Ankole.AIAgent.AgentDocumentsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.{Contracts, Knowledge}
  alias Ankole.{Pod, Repo}

  test "colleagues inherit the same whole organization contracts without copies" do
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()
    assert {:ok, left} = Library.list_agent_documents(first.uid)
    assert {:ok, right} = Library.list_agent_documents(second.uid)
    assert left == right
    {:ok, agents} = Knowledge.system_node("ankole_brain_agents")
    {:ok, page} = Knowledge.child(agents.id, first.uid)
    assert Ankole.Files.Nodes.list_children(page.id) == []
    assert left["agents"]["content"] != ""
    assert left["design"]["content"] != ""
  end

  test "Agent append contracts compose deterministically and override wins in the same directory" do
    %{principal: agent} = agent_fixture()
    {:ok, root} = Knowledge.root()
    {:ok, agents} = Knowledge.system_node("ankole_brain_agents")
    {:ok, home} = Knowledge.child(agents.id, agent.uid)
    put(root.id, "AGENTS.md", "Company policy")
    put(home.id, "AGENTS.md", "Department role")
    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert documents["agents"]["content"] =~ "Company policy\n\nDepartment role"
    assert length(documents["agents"]["page_ids"]) == 2

    put(home.id, "AGENTS.override.md", "Independent role")
    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert String.trim(documents["agents"]["content"]) == "Independent role"
    assert length(documents["agents"]["page_ids"]) == 1
  end

  test "DESIGN metadata recursively merges objects, replaces arrays and deletes null keys" do
    %{principal: agent} = agent_fixture()
    {:ok, root} = Knowledge.root()
    {:ok, agents} = Knowledge.system_node("ankole_brain_agents")
    {:ok, home} = Knowledge.child(agents.id, agent.uid)

    put(
      root.id,
      "DESIGN.md",
      "---\ncolors:\n  main: blue\n  muted: gray\nfonts: [one, two]\nspacing: 4\n---\nCompany design"
    )

    put(
      home.id,
      "DESIGN.md",
      "---\ncolors:\n  main: red\nfonts: [three]\nspacing: null\n---\nDepartment design"
    )

    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert {:ok, parsed} = Ankole.Kernel.knowledge_parse(documents["design"]["content"])

    assert parsed.metadata == %{
             "colors" => %{"main" => "red", "muted" => "gray"},
             "fonts" => ["three"]
           }

    assert documents["design"]["content"] =~ "Company design"
    assert documents["design"]["content"] =~ "Department design"
  end

  test "an empty Agent override deliberately clears either organization contract" do
    %{principal: agent} = agent_fixture()
    {:ok, root} = Knowledge.root()
    {:ok, agents} = Knowledge.system_node("ankole_brain_agents")
    {:ok, home} = Knowledge.child(agents.id, agent.uid)

    for name <- ["AGENTS", "DESIGN"] do
      put(root.id, name <> ".md", "---\norganization: shared\n---\nCompany contract")
      put(home.id, name <> ".md", "Agent addition")
      put(home.id, name <> ".override.md", "")
    end

    assert {:ok, documents} = Library.list_agent_documents(agent.uid)

    for kind <- ["agents", "design"] do
      assert String.trim(documents[kind]["content"]) == ""
      assert [_] = documents[kind]["page_ids"]
    end
  end

  test "template reconciliation preserves an organization edit" do
    %{principal: agent} = agent_fixture()
    {:ok, root} = Knowledge.root()
    put(root.id, "AGENTS.md", "Our company rule")
    assert {:ok, :ok} = Repo.transact_top_level(fn -> {:ok, Contracts.initialize_in_tx()} end)
    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert String.trim(documents["agents"]["content"]) == "Our company rule"
  end

  test "an unchanged factory contract upgrades and keeps its page identity" do
    %{principal: agent} = agent_fixture()
    {:ok, root} = Knowledge.root()
    {:ok, node} = Knowledge.child(root.id, "AGENTS.md")
    {:ok, parsed} = Ankole.Kernel.knowledge_parse("Earlier factory contract")
    {:ok, canonical} = Ankole.Kernel.knowledge_export(parsed.xml, parsed.metadata)

    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, _} <- Pod.Pages.lock(node.id),
             do:
               Pod.Knowledge.put_in_tx(node.id, %{
                 xml: parsed.xml,
                 metadata: parsed.metadata,
                 upstream_state: %{
                   "upstream_base_hash" => Ankole.AIAgent.Library.SourceReader.hash(canonical)
                 }
               })
      end)

    assert {:ok, :ok} = Repo.transact_top_level(fn -> {:ok, Contracts.initialize_in_tx()} end)
    assert {:ok, documents} = Library.list_agent_documents(agent.uid)
    assert documents["agents"]["page_id"] == node.id
    refute documents["agents"]["content"] =~ "Earlier factory contract"
    assert String.trim(documents["agents"]["content"]) != ""
  end

  test "namespace reconciliation claims an existing folder and rejects conflicting kinds" do
    agent_fixture()
    {:ok, root} = Knowledge.root()

    assert {:ok, namespace} =
             Repo.transact_top_level(fn ->
               with {:ok, _} <- Ankole.Ash.update(root, :claim_system, %{system_key: nil}),
                    do: Knowledge.ensure_namespace_in_tx()
             end)

    assert namespace.root.id == root.id
    assert namespace.root.system_key == "ankole_brain"

    assert {:ok, {:error, {:knowledge_path_kind_conflict, "AGENTS.md", :folder}}} =
             Repo.transact_top_level(fn ->
               {:ok, Knowledge.ensure_child_in_tx(root.id, "AGENTS.md", :folder)}
             end)
  end

  test "personal assistant contract pages are private to the owner and assistant" do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    %{principal: colleague} = human_fixture()
    assert {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(owner.uid)
    {:ok, agents} = Knowledge.system_node("ankole_brain_agents")
    {:ok, home} = Knowledge.child(agents.id, assistant.uid)
    refute home.inherit_permissions
    assert {:ok, _} = Ankole.Files.Nodes.authorize(owner.uid, home.id, "node_edit")
    assert {:error, _} = Ankole.Files.Nodes.authorize(colleague.uid, home.id, "node_view")
    assert {:ok, documents} = Library.list_agent_documents(assistant.uid)
    assert [id] = documents["agents"]["page_ids"]
    assert {:ok, %{name: "AGENTS.override.md"}} = Ankole.Files.Nodes.fetch(id)
  end

  defp put(parent, name, markdown) do
    {:ok, page} =
      Repo.transact_top_level(fn ->
        with {:ok, node} <- Knowledge.ensure_child_in_tx(parent, name, :knowledge),
             {:ok, _} <- Pod.Pages.lock(node.id),
             {:ok, parsed} <- Ankole.Kernel.knowledge_parse(markdown),
             do: Pod.Knowledge.put_in_tx(node.id, %{xml: parsed.xml, metadata: parsed.metadata})
      end)

    page
  end
end
