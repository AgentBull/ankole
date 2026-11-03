defmodule Ankole.Brain.ObjectWritesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Brain.{ObjectWrites, Objects, Tools.Context}
  alias Ankole.Pod.{Knowledge, Pages}

  setup do
    owner = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal
    category = Ankole.BrainFixtures.category_fixture(owner.uid)

    {:ok, :ok} =
      Repo.transact(fn ->
        :ok =
          Ankole.Pod.Access.put_role(
            %{principal_uid: agent.uid},
            "drive:**:#{category.id}:**",
            "edit"
          )

        {:ok, :ok}
      end)

    context = %Context{
      querier_uid: agent.uid,
      disclosure: %{mode: :strict, asker_uid: owner.uid, present_uids: [owner.uid]}
    }

    %{owner: owner, agent: agent, context: context, category: category}
  end

  test "an authorized Agent creates and revises an attributed Brain object with CAS", ctx do
    assert {:ok, %{"status" => "saved", "object_id" => id, "revision" => revision}} =
             ObjectWrites.write(
               %{
                 "category" => "notes",
                 "title" => "Approved note",
                 "base_revision" => 0,
                 "markdown" => "Initial fact"
               },
               ctx.context
             )

    assert {:ok, page} = Objects.get_by_slug(id)
    assert page.body =~ "Initial fact"
    assert page.type == "note"
    assert {:ok, %{content: content}} = Knowledge.read_in_tx(id)
    assert content.updated_by.uid == ctx.agent.uid

    assert {:ok, %{"revision" => next}} =
             ObjectWrites.write(
               %{"object_id" => id, "base_revision" => revision, "markdown" => "Revised fact"},
               ctx.context
             )

    assert next > revision

    assert {:error, {:revision_conflict, ^next}} =
             ObjectWrites.write(
               %{"object_id" => id, "base_revision" => revision, "markdown" => "Stale fact"},
               ctx.context
             )
  end

  test "Brain background writes invalidate views only after a committed transaction", ctx do
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-content:" <> Repo.tenant_id!())
    attrs = %{slug: "notes/background", type: "note", title: "Background note", body: "first"}
    assert {:ok, object} = Ankole.Brain.create_object(attrs, ctx.owner.uid)
    assert_receive {:tree_changed, _, _, false}

    assert {:error, {:revision_conflict, _}} =
             Ankole.Brain.update_object(
               object.slug,
               %{body: "rolled back", base_revision: -1},
               ctx.owner.uid
             )

    refute_receive {:tree_changed, _, _, _}
    assert {:ok, current} = Objects.get_by_slug(object.slug)
    assert current.body == "first"

    assert {:ok, _} = Ankole.Brain.update_object(object.slug, %{body: "committed"}, ctx.owner.uid)
    assert_receive {:tree_changed, _, _, false}
  end

  test "browser creation derives ontology type and resolves model-visible paths", ctx do
    assert {:ok, page} =
             Pages.create(actor_fixture(ctx.owner), %{
               parent_id: ctx.category.id,
               type: :knowledge,
               title: "browser-note"
             })

    assert page.metadata["entity_type"] == "note"

    for path <- [
          "notes/browser-note",
          "Brain/notes/browser-note",
          "/drive/Brain/notes/browser-note"
        ] do
      assert {:ok, %{id: id}} = Objects.get_by_slug(path)
      assert id == page.id
    end

    assert {:error, :ontology_owned_category} = ObjectWrites.category("agents")
    assert {:ok, agents} = Ankole.Brain.Namespace.system_node("ankole_brain_agents")

    assert {:error, :ontology_owned_category} =
             Pages.create(actor_fixture(ctx.owner), %{
               parent_id: agents.id,
               type: :knowledge,
               title: "Wild agent"
             })
  end

  test "a requester without edit permission receives an approval proposal without a write", ctx do
    viewer = human_fixture().principal

    context = %{
      ctx.context
      | disclosure: %{mode: :strict, asker_uid: viewer.uid, present_uids: [viewer.uid]}
    }

    assert {:ok, %{"status" => "approval_required", "proposal" => proposal}} =
             ObjectWrites.write(
               %{
                 "category" => "notes",
                 "title" => "Proposed note",
                 "base_revision" => 0,
                 "markdown" => "Proposal"
               },
               context
             )

    assert proposal["action_kind"] == "brain.object.create"
    assert proposal["node_id"] == ctx.category.id

    refute Enum.any?(
             Ankole.Pod.Pages.Tree.list_children(ctx.category.id),
             &(&1.title == "Proposed note")
           )
  end

  test "Principal lifecycle archives identity metadata while preserving content and path ownership",
       ctx do
    {:ok, id} = Ankole.Brain.Scope.canonical_page_id(ctx.agent.uid)

    {:ok, :ok} =
      Repo.transact(fn ->
        :ok =
          Ankole.Pod.Access.put_role(
            %{principal_uid: ctx.owner.uid},
            "drive:**:#{id}:**",
            "manage"
          )

        {:ok, :ok}
      end)

    {:ok, page} = Pages.fetch(id)

    {:ok, _} =
      Knowledge.write(
        actor_fixture(ctx.owner),
        id,
        page.revision,
        "<page><p>Agent profile</p></page>",
        %{}
      )

    {:ok, changed} = Pages.fetch(id)
    assert changed.metadata["subtype"] == "internal"
    assert {:error, :principal_owned_object} = Pages.delete(actor_fixture(ctx.owner), id)
    assert {:ok, _} = Ankole.Principals.disable_agent(ctx.agent.uid)
    assert {:ok, archived} = Objects.get_by_slug(id)
    assert archived.meta["archived"]
    assert archived.body =~ "Agent profile"
    assert {:ok, _} = Ankole.Principals.enable_agent(ctx.agent.uid)
    assert {:ok, restored} = Objects.get_by_slug(id)
    refute restored.meta["archived"]
    assert restored.body == archived.body
  end
end
