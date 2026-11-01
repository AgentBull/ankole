defmodule Ankole.Principals.PersonalAssistantTest do
  use Ankole.DataCase, async: true

  alias Ankole.Principals
  alias Ankole.Principals.WorkAccess
  import Ankole.PrincipalsFixtures

  test "names identify principals inside their tenant", %{tenant: first} do
    other = create_tenant()

    for tenant <- [first, other] do
      Repo.with_tenant(tenant.id, fn ->
        assert {:ok, %{principal: human}} =
                 Principals.create_human(%{email: " ALICE@example.com ", display_name: "Alice"})

        assert human.uid == "alice@example.com"
        assert {:ok, %{uid: "system"}} = Principals.system_principal()
        %{principal: agent} = agent_fixture(%{uid: "research+team@example.com"})
        assert agent.uid == "research+team@example.com"
        assert agent.tenant_id == tenant.id
      end)
    end
  end

  test "a duplicate name returns a conflict without claiming the existing principal" do
    %{principal: owner} = human_fixture(%{email: "owner@example.com"})
    worker_provider_fixture(%{is_default: true})
    agent_fixture(%{uid: owner.uid <> "_assistant"})

    assert {:error, :principal_uid_taken} =
             Principals.ensure_personal_assistant(owner.uid) |> Ankole.Errors.reason()

    assert is_nil(Principals.personal_assistant(owner.uid))
  end

  test "first use creates a full Agent and later calls reuse its owner relationship" do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    assert is_nil(Principals.personal_assistant(owner.uid))

    assert {:ok, %{principal: pa, agent: agent}} = Principals.ensure_personal_assistant(owner.uid)
    assert pa.uid == owner.uid <> "_assistant"
    assert agent.type == :personal_assistant
    assert agent.group_memory_disclosure_mode == :strict
    assert Principals.authority_uid(pa.uid) == owner.uid
    assert {:ok, %{principal: %{uid: same_uid}}} = Principals.ensure_personal_assistant(owner.uid)
    assert same_uid == pa.uid
    assert Ankole.AgentWorkers.get_agent_worker!(pa.uid)
    assert {:ok, library} = Ankole.AIAgent.Library.list_agent_documents(pa.uid)
    assert library["soul"]["content"] =~ "personal assistant"
    assert :ok = Ankole.AuthZ.authorize(owner.uid, "agent:#{pa.uid}", "chat")
    assert WorkAccess.from_sender(pa.uid) == WorkAccess.from_sender(owner.uid)
  end

  test "direct creation and enable cannot bypass the assistant owner's membership" do
    %{principal: guest} = human_fixture(%{membership: :guest})
    provider = worker_provider_fixture(%{is_default: true})

    assert {:error, :personal_assistant_requires_member} =
             Principals.create_agent(%{
               uid: "guest-assistant",
               type: :personal_assistant,
               owner_principal_uid: guest.uid,
               display_name: "Assistant",
               role: "Personal assistant",
               worker_provider_id: provider.provider_id
             })

    %{principal: member} = human_fixture()
    assert {:ok, %{principal: assistant}} = Principals.ensure_personal_assistant(member.uid)
    assert {:ok, _} = Principals.change_human_membership(member.uid, :guest)
    assert {:error, :personal_assistant_requires_member} = Principals.enable_agent(assistant.uid)
  end

  test "business grants follow the owner while management permissions and attribution do not" do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    assert {:ok, %{principal: pa}} = Principals.ensure_personal_assistant(owner.uid)

    for resource <- ["agent:research", "tenant_console:drive_space", "site_console:agents"] do
      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: owner.uid,
                 resource_pattern: resource,
                 action: if(resource == "agent:research", do: "chat", else: "update"),
                 condition: "true"
               })
    end

    assert :ok = Ankole.AuthZ.authorize(pa.uid, "agent:research", "chat")

    assert {:ok, [true, false, true]} =
             Ankole.AuthZ.authorize_checks(pa.uid, [
               %{resource: "agent:research", action: "chat"},
               %{resource: "tenant_console:drive_space", action: "update"},
               %{resource: "agent:research", action: "chat"}
             ])

    assert {:error, {:forbidden, "update"}} =
             Ankole.AuthZ.authorize(pa.uid, "tenant_console:drive_space", "update")

    assert {:error, {:forbidden, "update"}} =
             Ankole.AuthZ.authorize(pa.uid, "site_console:agents", "update")

    assert {:ok, owner_context} = Ankole.Files.Access.context_snapshot(actor_fixture(owner))
    assert elem(owner_context, 0)["canManageSpace"]

    assert {:ok, {assistant_snapshot, _}} =
             Ankole.Files.Access.context_snapshot(actor_fixture(pa), context: owner_context)

    refute assistant_snapshot["canManageSpace"]

    actor = actor_fixture(pa)

    assert {:ok, page} =
             Ankole.Pod.Pages.create(actor, %{
               title: "Private notes",
               private_owner_uid: owner.uid
             })

    assert {:ok, [root | _]} = Ankole.Files.Nodes.path(page)
    assert root.private_owner_uid == owner.uid
    assert page.created_by.uid == pa.uid
    assert {:ok, root} = Ankole.Files.private_root(pa.uid)
    assert root.private_owner_uid == pa.uid
  end

  test "the public directory excludes assistants and mentions offer only the caller's existing assistant" do
    %{principal: owner} = human_fixture(%{display_name: "Owner"})
    %{principal: other} = human_fixture(%{display_name: "Other"})
    worker_provider_fixture(%{is_default: true})
    %{principal: colleague} = agent_fixture(%{uid: "research-colleague"})

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: owner.uid,
               resource_pattern: "agent:#{colleague.uid}",
               action: "chat",
               condition: "true"
             })

    actor = actor_fixture(owner)

    assert {:ok, before} =
             Ankole.Pod.Pages.Mentions.candidates(actor, %{
               query: "assistant",
               category: :principal
             })

    assert before.principals == []
    assert {:ok, %{principal: pa}} = Principals.ensure_personal_assistant(owner.uid)
    assert {:ok, %{principal: other_pa}} = Principals.ensure_personal_assistant(other.uid)

    assert Enum.map(Ankole.Conversations.agents(actor), & &1.uid) == [colleague.uid]

    for query <- ["ai", "assistant", "pa", "助理", "我的助理"] do
      assert {:ok, candidates} =
               Ankole.Pod.Pages.Mentions.candidates(actor, %{query: query, category: :principal})

      assert Enum.any?(candidates.principals, &(&1.principal_uid == pa.uid))
      refute Enum.any?(candidates.principals, &(&1.principal_uid == other_pa.uid))
    end

    assert {:ok, resolved} =
             Ankole.Pod.Pages.Mentions.resolve(actor, %{principal_uids: [other_pa.uid]})

    assert [%{name: name, access: :ok}] = resolved.principals
    assert name =~ "Other"
    assert {:ok, _} = Principals.update_human(other.uid, %{display_name: "New Owner"})
    assert Principals.display_name(other_pa) =~ "New Owner"
  end

  test "document attribution resolves the complete tenant and name", %{tenant: tenant} do
    other = create_tenant()
    %{principal: local} = human_fixture(%{email: "same@example.com", display_name: "Local"})

    remote =
      Repo.with_tenant(other.id, fn ->
        human_fixture(%{email: "same@example.com", display_name: "Remote"}).principal
      end)

    local_ref = Ankole.ActorRef.from_principal(local)
    remote_ref = Ankole.ActorRef.from_principal(remote)
    profiles = Ankole.Pod.Serialization.author_profiles([local_ref, remote_ref])
    assert profiles[local_ref].name == "Local"
    assert profiles[remote_ref].name == "Remote"
    assert Ankole.Pod.Serialization.author_json(remote_ref, profiles).tenant_id == other.id
    assert Repo.tenant_id!() == tenant.id
  end

  test "a guest can read an assistant mention in a shared document or comment without gaining chat permission" do
    %{principal: owner} = human_fixture(%{display_name: "Document Owner"})
    %{principal: guest} = human_fixture(%{membership: :guest})
    worker_provider_fixture(%{is_default: true})
    assert {:ok, %{principal: assistant}} = Principals.ensure_personal_assistant(owner.uid)
    owner_actor = actor_fixture(owner)
    guest_actor = actor_fixture(guest)
    mention = "<mention principal=\"#{assistant.uid}\" />"

    for location <- [:document, :comment] do
      xml =
        if location == :document,
          do: "<page><p>#{mention}</p></page>",
          else: "<page><p>Review</p></page>"

      assert {:ok, page} =
               Ankole.Pod.Pages.create(owner_actor, %{title: "Shared review", xml: xml})

      assert {:ok, _} =
               Ankole.Pod.Pages.update_sharing(owner_actor, page.id, %{
                 upserts: [%{principal_uid: guest.uid, role: "edit", target_scope: "self"}]
               })

      if location == :comment do
        assert {:ok, _} = Ankole.Pod.Comments.create(guest_actor, page.id, %{body: mention})
      end

      assert {:ok, %{principals: [%{access: :ok, name: name}]}} =
               Ankole.Pod.Pages.Mentions.resolve(guest_actor, %{
                 context_page_id: page.id,
                 principal_uids: [assistant.uid]
               })

      assert name =~ "Document Owner"

      assert {:ok, %{principals: []}} =
               Ankole.Pod.Pages.Mentions.candidates(guest_actor, %{
                 current_page_id: page.id,
                 query: "assistant",
                 category: :principal
               })

      assert {:error, _} = Ankole.Conversations.authorize_agent(guest_actor, assistant.uid)
    end
  end

  test "human revocation and restoration synchronize the existing assistant" do
    %{principal: owner} = human_fixture()
    worker_provider_fixture(%{is_default: true})
    assert {:ok, %{principal: pa}} = Principals.ensure_personal_assistant(owner.uid)
    Repo.delete_all(Oban.Job)
    assert {:ok, _} = disable_principal_fixture(owner.uid)

    assert Repo.exists?(
             from job in Oban.Job,
               where:
                 job.worker == "Ankole.AgentWorkers.ReconcileJob" and
                   fragment("?->>'agent_uid'", job.args) == ^pa.uid
           )

    assert {:ok, %{status: :disabled}} = Principals.get_principal(pa.uid)
    refute WorkAccess.valid_now?(WorkAccess.from_sender(pa.uid))
    assert {:error, :human_access_revoked} = Principals.ensure_personal_assistant(owner.uid)

    assert {:ok, _} =
             Principals.HumanAccess.restore(owner.uid, nil, "restore", Ash.UUIDv7.generate())

    assert {:ok, %{status: :active}} = Principals.get_principal(pa.uid)
    assert {:ok, %{principal: %{uid: uid}}} = Principals.ensure_personal_assistant(owner.uid)
    assert uid == pa.uid
  end
end
