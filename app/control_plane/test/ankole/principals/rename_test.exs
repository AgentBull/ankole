defmodule Ankole.Principals.RenameTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AgentWorkers, BrowserSessions, Pod, Principals}
  alias Ankole.Pod.{PageContent, PageComment, Pages}

  test "a Human rename preserves login, ownership, mentions and tenant-qualified attribution", %{
    tenant: tenant
  } do
    %{principal: owner} = human_fixture(%{email: "before@example.com"})
    other = create_tenant()
    remote = Repo.with_tenant(other.id, fn -> human_fixture(%{email: owner.uid}).principal end)
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Principals.ensure_personal_assistant(owner.uid)
    actor = actor_fixture(owner)
    avatar_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4>>

    assert {:ok, %{avatarURL: initial_avatar_url}} =
             Principals.upload_member_avatar(actor, avatar_bytes, "image/png")

    assert initial_avatar_url =~
             "/api/v2/pod/avatars/" <> URI.encode_www_form("member:" <> owner.uid) <> "?v="

    {:ok, page} =
      Pages.create(actor, %{
        title: "Mentions",
        xml: "<page><p><mention principal=\"#{owner.uid}\" /></p></page>"
      })

    {:ok, plain} =
      Pages.create(actor, %{title: "Plain text", xml: "<page><p>#{owner.uid}</p></page>"})

    {:ok, %{comment: comment}} =
      Pod.Comments.create(actor, page.id, %{body: "<mention principal=\"#{owner.uid}\" />"})

    home = Repo.get_by!(Ankole.Brain.Schemas.Page, slug: "people/" <> owner.uid)
    {:ok, browser} = BrowserSessions.create()

    {:ok, login} =
      BrowserSessions.authenticate(BrowserSessions.reference(browser), %{
        "principal_uid" => owner.uid,
        "access_version" => owner.access_version,
        "provider_id" => "local",
        "external_id" => owner.uid,
        "auth_time" => System.system_time(:second)
      })

    authentication = BrowserSessions.reference(login.authentication)

    assert {:ok, %{principal: renamed, base_repair_error: nil}} =
             Principals.rename(owner.uid, "after@example.com")

    assert renamed.uid == "after@example.com"

    assert renamed.avatar_url =~
             "/api/v2/pod/avatars/" <> URI.encode_www_form("member:" <> renamed.uid) <> "?v="

    assert {:error, :not_found} = Principals.fetch_avatar("member:" <> owner.uid)
    assert {:ok, moved_avatar} = Principals.fetch_avatar("member:" <> renamed.uid)
    assert {:ok, ^avatar_bytes} = Ankole.Files.read_object(moved_avatar.object_id)
    assert BrowserSessions.identity(authentication, tenant.id)["principal_uid"] == renamed.uid

    assert {:ok, %{principal: same_assistant, agent: %{owner_principal_uid: uid}}} =
             Principals.ensure_personal_assistant(renamed.uid)

    assert same_assistant.uid == assistant.uid
    assert uid == renamed.uid
    assert Repo.get_by!(Principals.HumanUser, principal_uid: renamed.uid).email == owner.uid
    assert {:error, :not_found} == Principals.get_principal(owner.uid)

    assert {:ok, remote_after} =
             Repo.with_tenant(other.id, fn -> Principals.get_principal(remote.uid) end)

    assert_persisted_equal(remote_after, remote)

    saved = Repo.get_by!(PageContent, page_id: page.id)
    assert saved.content =~ "principal=\"#{renamed.uid}\""
    assert Repo.get_by!(Pod.Page, id: page.id).revision > page.revision
    assert Repo.get_by!(Pod.Page, id: plain.id).revision == plain.revision
    assert Repo.get_by!(PageContent, page_id: plain.id).content =~ owner.uid
    assert saved.updated_by.uid == renamed.uid
    assert Repo.get!(PageComment, comment.id).body =~ renamed.uid
    assert Repo.get!(PageComment, comment.id).author.uid == renamed.uid
    assert Repo.get_by!(Ankole.Brain.Schemas.Page, slug: "people/" <> renamed.uid).id == home.id
    refute Repo.get_by(Ankole.Brain.Schemas.Page, slug: "people/" <> owner.uid)
  end

  test "Human rename rejects UID syntax that cannot name a route or a permission resource" do
    owner = human_fixture(%{email: "valid-name@example.com"}).principal

    for uid <- [
          "alice/dev",
          "alice:dev",
          "alice*",
          "alice?",
          "alice[0]",
          "alice{0}",
          "alice dev",
          "alice\nother",
          "alice\\other",
          "alice\u202Edev"
        ] do
      assert {:error, :invalid_uid} = Principals.rename(owner.uid, uid)
      assert {:ok, _} = Principals.get_principal(owner.uid)
    end
  end

  test "Markdown comment mentions follow a rename while code and ordinary text remain unchanged" do
    owner = human_fixture(%{email: "markdown@example.com"}).principal
    {:ok, page} = Pages.create(actor_fixture(owner), %{title: "Mentions"})

    body =
      "@[Owner](principal:#{owner.uid}) and `@[Code](principal:#{owner.uid})` and #{owner.uid}"

    {:ok, %{comment: comment}} = Pod.Comments.create(actor_fixture(owner), page.id, %{body: body})
    assert {:ok, _} = Principals.rename(owner.uid, "renamed@example.com")

    assert Repo.get!(PageComment, comment.id).body ==
             "@[Owner](principal:renamed@example.com) and `@[Code](principal:#{owner.uid})` and #{owner.uid}"
  end

  test "inline Base users follow their tenant while author references match the complete identity" do
    owner = human_fixture(%{email: "base-owner@example.com"}).principal
    local = base_record(owner)
    other = create_tenant()

    foreign =
      Repo.with_tenant(other.id, fn ->
        same_name = human_fixture(%{email: owner.uid}).principal
        result = base_record(same_name)
        row = Repo.get_by!(Pod.BaseRecord, id: result.record.id, table_id: result.table.id)

        row
        |> Ecto.Changeset.change(created_by: Ankole.ActorRef.from_principal(owner))
        |> Repo.update!()

        result
      end)

    assert {:ok, %{principal: renamed, base_repair_error: nil}} =
             Principals.rename(owner.uid, "new-base-owner@example.com")

    assert {:ok, %{records: [record]}} =
             Pod.Bases.query(actor_fixture(renamed), local.table.id, %{ids: [local.record.id]})

    assert record["data"][local.field.id] == [renamed.uid]
    assert record["created_by"] == to_string(Ankole.ActorRef.from_principal(renamed))

    Repo.with_tenant(other.id, fn ->
      row = Repo.get_by!(Pod.BaseRecord, id: foreign.record.id, table_id: foreign.table.id)
      assert row.data[foreign.field.id] == [owner.uid]
      assert row.created_by == Ankole.ActorRef.from_principal(renamed)
      assert row.updated_by.tenant_id == other.id
      assert row.updated_by.uid == owner.uid
    end)
  end

  test "canonical XML mentions follow names containing an apostrophe without changing text" do
    owner = human_fixture(%{email: "o'connor@example.com"}).principal
    actor = actor_fixture(owner)

    {:ok, page} =
      Pages.create(actor, %{
        title: "Mention with XML attributes",
        xml:
          "<page><p>#{owner.uid}<mention label=\"Teammate\" principal=\"#{owner.uid}\" /></p></page>"
      })

    mention = "<mention principal=\"#{owner.uid}\" />"
    comment_body = "Hello #{mention}. Example: `#{mention}`."
    {:ok, %{comment: comment}} = Pod.Comments.create(actor, page.id, %{body: comment_body})

    assert {:ok, %{principal: renamed}} = Principals.rename(owner.uid, "new.o'connor@example.com")
    content = Repo.get_by!(PageContent, page_id: page.id)
    assert content.content =~ "principal=\"#{renamed.uid}\""
    assert content.content =~ "label=\"Teammate\""
    assert content.content =~ ">#{owner.uid}<"

    assert Repo.get!(PageComment, comment.id).body ==
             "Hello <mention principal=\"#{renamed.uid}\" />. Example: `#{mention}`."

    snapshots = Repo.all(from(s in Pod.PageSnapshot, where: s.page_id == ^page.id))
    assert snapshots != []
    assert Enum.all?(snapshots, &String.contains?(&1.content, "principal=\"#{renamed.uid}\""))
  end

  test "private knowledge, typed mentions and historical restores follow a Principal rename" do
    owner = human_fixture(%{email: "brain-before@example.com"}).principal
    outsider = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, home} = Ankole.Brain.Objects.get_by_slug("people/" <> owner.uid)
    category = Ankole.BrainFixtures.category_fixture(owner.uid)

    xml =
      "<page><p>Private note. <mention principal=\"#{owner.uid}\" /><mention page=\"#{home.id}\" /></p><pre>#{owner.uid}</pre></page>"

    {:ok, page} =
      Pages.create(actor, %{
        type: :knowledge,
        parent_id: category.id,
        title: "Rename review",
        xml: xml,
        metadata: %{"summary" => "Private review"}
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: owner.uid, role: "manage"}]
      })

    {:ok, %{snapshots: [original]}} = Pod.Documents.History.list(actor, page.id)
    {:ok, _} = Pod.Knowledge.write(actor, page.id, 0, xml, %{"summary" => "Updated review"})

    assert {:ok, %{principal: renamed}} = Principals.rename(owner.uid, "brain-after@example.com")
    renamed_actor = actor_fixture(renamed)
    assert {:ok, %{page: current, content: content}} = Pages.get(renamed_actor, page.id)
    assert content.content =~ "principal=\"#{renamed.uid}\""
    assert content.content =~ "page=\"#{home.id}\""
    assert content.content =~ "<pre>#{owner.uid}</pre>"
    assert {:error, :forbidden} = Pages.get(actor_fixture(outsider), page.id)
    assert {:ok, canonical} = Ankole.Brain.Objects.get_by_slug("people/" <> renamed.uid)
    assert canonical.id == home.id

    assert {:ok, %{page: restored, content: restored_content}} =
             Pod.Documents.History.restore(
               renamed_actor,
               page.id,
               original.id,
               current.revision,
               current.updated_at
             )

    assert restored.metadata == %{"entity_type" => "note", "summary" => "Private review"}
    assert restored_content.content =~ "principal=\"#{renamed.uid}\""
    assert restored_content.content =~ "page=\"#{home.id}\""
    assert restored_content.content =~ "<pre>#{owner.uid}</pre>"

    replacement = human_fixture(%{email: "replacement@example.com"}).principal
    assert {:ok, %{principal: replacement}} = Principals.rename(replacement.uid, owner.uid)
    assert {:error, :forbidden} = Pages.get(actor_fixture(replacement), page.id)
  end

  test "chat targets and typed JSON mentions follow the rename while user text keeps its bytes" do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{uid: "colleague"})
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    message_id = Ankole.Kernel.gen_uuid_v7()

    {:ok, detail} =
      Ankole.ConversationsFixtures.create(human.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: message_id,
        agent_uid: agent.uid,
        text: "colleague",
        mentions: [%{type: "agent", uid: agent.uid}],
        target_agent_uid: agent.uid
      })

    assert {:ok, _} = Principals.disable_agent(agent.uid)
    assert {:ok, %{principal: renamed}} = Principals.rename(agent.uid, "renamed-colleague")
    message = Repo.get_by!(Ankole.Conversations.Message, id: message_id)
    assert message.rich_content["target_agent_uid"] == renamed.uid
    assert [%{"uid" => uid}] = message.mentions
    assert uid == renamed.uid
    assert message.text == "colleague"

    participants =
      Ankole.Conversations.Participant
      |> where(conversation_id: ^detail.conversation.id)
      |> Repo.all()

    assert Enum.any?(participants, &(&1.principal_uid == renamed.uid))
  end

  test "Agent rename keeps delegated Skill-binding grants", %{} do
    owner = human_fixture().principal
    agent = agent_fixture(%{uid: "skill-delegate"}).principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:agent_skill_binding:#{agent.uid}",
        action: "update"
      })

    {:ok, _} = Principals.disable_agent(agent.uid)
    assert {:ok, _} = Principals.rename(agent.uid, "renamed-skill-delegate")

    assert :ok =
             Ankole.AuthZ.authorize(
               actor_fixture(owner),
               "tenant_console:agent_skill_binding:renamed-skill-delegate",
               "update"
             )

    assert {:error, _} =
             Ankole.AuthZ.authorize(
               actor_fixture(owner),
               "tenant_console:agent_skill_binding:skill-delegate",
               "update"
             )
  end

  test "an Agent rename preserves historical Delivery attachment references" do
    %{principal: agent} = agent_fixture(%{uid: "attachment-owner"})
    tenant = Ecto.UUID.dump!(Repo.tenant_id!())

    Repo.query!(
      "INSERT INTO deliveries(tenant_id,agent_uid,binding_name,outbound_key,operation,inserted_at,updated_at) VALUES($1,$2,'legacy','attachment','post',now(),now())",
      [tenant, agent.uid]
    )

    Repo.query!(
      "INSERT INTO delivery_attachments(tenant_id,agent_uid,binding_name,outbound_key,position,metadata) VALUES($1,$2,'legacy','attachment',0,'{\"name\":\"report.txt\"}')",
      [tenant, agent.uid]
    )

    assert {:ok, _} = Principals.disable_agent(agent.uid)
    assert {:ok, %{principal: renamed}} = Principals.rename(agent.uid, "renamed-attachment-owner")

    assert [[uid]] =
             Repo.query!(
               "SELECT agent_uid FROM delivery_attachments WHERE tenant_id=$1 AND outbound_key='attachment'",
               [tenant]
             ).rows

    assert uid == renamed.uid
  end

  test "renaming a disabled Agent moves encrypted configuration and creates a new Worker identity" do
    %{principal: agent} = agent_fixture(%{uid: "research"})

    assert {:ok, _} =
             AgentWorkers.WorkerEnv.console_put_for_agent(agent.uid, "RENAME_SECRET", %{
               "value" => "secret bytes",
               "secret" => true
             })

    assert {:error, :agent_must_be_disabled} =
             Principals.rename(agent.uid, "research+team@example.com")

    assert {:ok, _} = Principals.disable_agent(agent.uid)

    assert {:ok, %{principal: renamed, base_repair_error: nil}} =
             Principals.rename(agent.uid, "research+team@example.com")

    assert {:ok, "secret bytes"} =
             AgentWorkers.WorkerEnv.console_decrypt_for_agent(renamed.uid, "RENAME_SECRET")

    assert %{state: :deleting} = AgentWorkers.get_agent_worker!(agent.uid)
    assert %{state: :absent} = AgentWorkers.get_agent_worker!(renamed.uid)
    assert {:ok, _} = Principals.enable_agent(renamed.uid)
  end

  test "an assistant rename preserves the one-assistant owner relationship and grants" do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Principals.ensure_personal_assistant(owner.uid)
    assert {:ok, _} = Principals.disable_agent(assistant.uid)
    assert {:ok, %{principal: renamed}} = Principals.rename(assistant.uid, "my-assistant")
    assert {:ok, _} = Principals.enable_agent(renamed.uid)

    assert {:ok, %{principal: %{uid: "my-assistant"}}} =
             Principals.ensure_personal_assistant(owner.uid)

    assert :ok = Ankole.AuthZ.authorize(owner.uid, "agent:my-assistant", "chat")

    assert :ok =
             Ankole.AuthZ.authorize(owner.uid, "drive:private:my-assistant:notes", "node_manage")
  end

  test "a name collision rolls back all control-plane references" do
    %{principal: first} = human_fixture(%{email: "first@example.com"})
    %{principal: second} = human_fixture(%{email: "second@example.com"})

    assert {:error, :principal_uid_taken} =
             Principals.rename(first.uid, second.uid) |> Ankole.Errors.reason()

    assert {:ok, unchanged_first} = Principals.get_principal(first.uid)
    assert {:ok, unchanged_second} = Principals.get_principal(second.uid)
    assert_persisted_equal(unchanged_first, first)
    assert_persisted_equal(unchanged_second, second)
  end

  defp base_record(principal) do
    actor = actor_fixture(principal)
    {:ok, page} = Pages.create(actor, %{type: "base"})
    {:ok, table} = Pod.Bases.create_table(actor, page.id, %{name: "People"})
    {:ok, field} = Pod.Bases.create_field(actor, table.id, %{name: "Owner", type: "user"})

    {:ok, %{records: [record]}} =
      Pod.Bases.write_records(actor, table.id, %{
        creates: [%{data: %{field.id => [principal.uid]}}]
      })

    %{table: table, field: field, record: record}
  end
end
