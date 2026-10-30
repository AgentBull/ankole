defmodule Ankole.AuthZ.NativeAuthorizerTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  require Ash.Query
  alias Ankole.AuthZ.{Actor, Root}
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Pod.{Bases, BaseField, BaseRecord, Page, Pages}
  alias Ankole.Principals.PodAdminOperations

  test "protected operations reject a bare Principal and an ungranted Actor, then accept the Pod administrator" do
    human = human_fixture().principal
    actor = Actor.new(human)

    input =
      Ash.ActionInput.for_action(PodAdminOperations, :settings, %{}, tenant: Repo.tenant_id!())

    assert {:error, %Ash.Error.Forbidden{}} = Ankole.Ash.run_action_authorized(input, actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.run_action(input, actor: human, authorize?: true)

    {:ok, _} =
      Repo.transact(fn ->
        {:ok, group} = Root.ensure_pod_admin_group()
        {:ok, _} = Ankole.AuthZ.Grants.upsert_pod_admin_grants(group)
        AuthZ.add_pod_admin_in_tx(human.uid)
      end)

    assert {:ok, %{displayName: _}} = Ankole.Ash.run_action_authorized(input, actor)
  end

  test "Page reads use the native anchor filter and preserve the intersection of interactive subjects" do
    owner = human_fixture().principal
    other = human_fixture().principal

    {:ok, shared} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{title: "Shared"})

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        title: "Other private",
        private_owner_uid: other.uid
      })

    actor = Actor.new(owner)

    assert {:ok, ids} =
             Repo.transact_repeatable_read_only(fn ->
               with {:ok, pages} <-
                      Ankole.Ash.read_authorized(Ash.Query.for_read(Page, :list_roots), actor),
                    do: {:ok, Enum.map(pages, & &1.id)}
             end)

    assert shared.id in ids
    refute private.id in ids
    other_actor = Actor.new(other)

    assert {:ok, pages} =
             Repo.transact_repeatable_read_only(fn ->
               Ankole.Ash.read_authorized(Ash.Query.filter(Page, id == ^private.id), other_actor)
             end)

    assert Enum.map(pages, & &1.id) == [private.id]
    combined = %{other_actor | interactive_principal: owner}

    assert {:ok, []} =
             Repo.transact_repeatable_read_only(fn ->
               Ankole.Ash.read_authorized(Ash.Query.filter(Page, id == ^private.id), combined)
             end)
  end

  test "authentication facts enter the real CEL permission engine" do
    human = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: human.uid,
        resource_pattern: "tenant_console:invitations",
        action: "update",
        condition:
          ~s[context.request.authn.provider_scope == "tenant" || context.request.authn.amr.contains("mfa")]
      })

    email = Actor.new(human, authn: %{"provider_scope" => "site", "amr" => ["otp"]})
    sso = Actor.new(human, authn: %{"provider_scope" => "tenant", "amr" => ["oidc"]})
    assert {:error, _} = AuthZ.authorize(email, "tenant_console:invitations", "update")
    assert :ok = AuthZ.authorize(sso, "tenant_console:invitations", "update")
    refute Root.pod_admin?(human.uid)
  end

  test "native Page reads evaluate one graph and cannot reuse another Actor's policy" do
    owner = Actor.new(human_fixture().principal)
    outsider = Actor.new(human_fixture().principal)

    {:ok, private} = Pages.create(owner, %{private_owner_uid: Actor.uid(owner)})

    assert {:ok, :checked} =
             Repo.transact_repeatable_read_only(fn ->
               {{:ok, pages, executed}, queries} =
                 capture_authorization_queries(fn ->
                   Ankole.Ash.read_authorized(Ash.Query.for_read(Page, :list_roots), owner,
                     return_query?: true
                   )
                 end)

               assert Enum.map(pages, &{&1.id, &1.role}) == [{private.id, "manage"}]
               assert Enum.frequencies(queries) == %{snapshot: 1, graph: 1}
               assert length(executed.after_action) == 1
               assert {^owner, _policy} = executed.context.private.pod_authorization

               {{:ok, [], executed}, queries} =
                 capture_authorization_queries(fn ->
                   Ankole.Ash.read_authorized(executed, outsider, return_query?: true)
                 end)

               assert Enum.frequencies(queries) == %{snapshot: 1, graph: 1}
               assert {^outsider, _policy} = executed.context.private.pod_authorization
               {:ok, :checked}
             end)
  end

  defp capture_authorization_queries(fun) do
    handler = {__MODULE__, make_ref()}
    caller = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == caller do
            cond do
              String.contains?(metadata.query, "WITH subject AS") ->
                send(caller, {handler, :snapshot})

              String.contains?(metadata.query, "SELECT graph.anchor_id") ->
                send(caller, {handler, :graph})

              true ->
                :ok
            end
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, received_authorization_queries(handler)}
    after
      :telemetry.detach(handler)
    end
  end

  defp received_authorization_queries(handler) do
    receive do
      {^handler, query} -> [query | received_authorization_queries(handler)]
    after
      0 -> []
    end
  end

  test "Bases writes, schema changes and copies keep the interactive Human permission intersection" do
    owner = human_fixture().principal
    outsider = human_fixture().principal
    agent = agent_fixture().principal

    {:ok, parent} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        type: "base",
        parent_id: parent.id
      })

    {:ok, table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id, %{
        name: "Protected"
      })

    for action <- ~w(page_view page_write_records page_edit page_manage page_comment) do
      {:ok, _} =
        AuthZ.create_permission_grant(%{
          principal_uid: agent.uid,
          resource_pattern: "pod:**:#{parent.id}:**",
          action: action
        })
    end

    actor = Actor.new(agent, interactive_principal: outsider)
    batch = %{creates: [%{data: %{}}]}

    assert {:ok, _} =
             Bases.get_table(Ankole.PrincipalsFixtures.actor_fixture(agent.uid), table.id)

    assert {:error, :forbidden} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(actor),
               table.id,
               batch
             )

    assert {:error, :forbidden} =
             Bases.create_field(Ankole.PrincipalsFixtures.actor_fixture(actor), table.id, %{
               name: "Denied",
               type: "text"
             })

    assert {:error, :forbidden} =
             Bases.copy_table(Ankole.PrincipalsFixtures.actor_fixture(actor), table.id, %{
               parent_id: parent.id
             })

    assert Repo.aggregate(BaseRecord, :count) == 0
    refute Repo.get_by(BaseField, table_id: table.id, name: "Denied")

    assert {:ok, %{records: [record]}} =
             Bases.write_records(
               Ankole.PrincipalsFixtures.actor_fixture(Actor.new(agent)),
               table.id,
               batch
             )

    assert Repo.get_by!(BaseRecord, id: record.id, table_id: table.id).created_by.uid == agent.uid
  end

  test "domain point checks require both the Agent and its interactive Human" do
    agent = agent_fixture().principal
    human = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: agent.uid,
        resource_pattern: "tenant_console:pod_space",
        action: "update"
      })

    actor = Actor.new(agent, interactive_principal: human)
    assert :ok = AuthZ.authorize(Actor.primary(actor), "tenant_console:pod_space", "update")

    assert {:error, {:forbidden, "update"}} =
             AuthZ.authorize(actor, "tenant_console:pod_space", "update")
  end

  test "grant targets include accepted changeset attributes and reject malformed resource segments" do
    changeset =
      Ash.Changeset.for_create(
        Ankole.AuthZ.Group,
        :create,
        %{name: "  Operators  ", display_name: "Operators"},
        tenant: Repo.tenant_id!()
      )

    assert {:ok, "site_console:principal_group:operators"} =
             Ankole.AuthZ.Checks.GrantCheck.expand(
               "site_console:principal_group:{name}",
               changeset
             )

    input =
      Ash.ActionInput.for_action(PodAdminOperations, :save_provider, %{},
        tenant: Repo.tenant_id!()
      )

    assert {:error, :forbidden} =
             Ankole.AuthZ.Checks.GrantCheck.expand(
               "tenant_console:identity_provider:{provider_id}",
               input
             )

    for type <- [:uuid, :string, :principal_key, :provider_id, :model_profile],
        value <- [nil, "", "scope:admin", "*"] do
      assert {:error, :forbidden} = Ankole.AuthZ.Checks.GrantCheck.resolve(type, value)
    end

    assert {:error, :forbidden} = Ankole.AuthZ.Checks.GrantCheck.resolve(:uuid, "not-a-uuid")
  end

  test "operation surface overrides ingress surface while retaining trusted authentication evidence" do
    human = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: human.uid,
        resource_pattern: "agent:surface-test",
        action: "chat",
        condition:
          ~s(context.request.surface == "conversation" && context.request.authn.provider_scope == "tenant")
      })

    actor = Actor.new(human, authn: %{"surface" => "pod_browser", "provider_scope" => "tenant"})

    assert :ok =
             AuthZ.authorize(actor, "agent:surface-test", "chat", %{"surface" => "conversation"})

    assert {:error, _} = AuthZ.authorize(actor, "agent:surface-test", "chat")

    for authn <- [%{}, %{"provider_scope" => "site"}] do
      weak = Actor.new(human, authn: authn)

      assert {:error, _} =
               AuthZ.authorize(weak, "agent:surface-test", "chat", %{
                 "surface" => "conversation",
                 "authn" => %{"provider_scope" => "tenant"}
               })
    end
  end

  test "Agent and interactive Human evaluate their own authentication evidence" do
    agent = agent_fixture().principal
    human = human_fixture().principal

    actor =
      Actor.new(agent,
        interactive_principal: human,
        authn: %{"surface" => "agent_rpc"},
        interactive_authn: %{
          "surface" => "agent_rpc",
          "provider_scope" => "tenant",
          "amr" => ["oidc"]
        }
      )

    assert Actor.primary(actor).authn == %{"surface" => "agent_rpc"}
    assert Actor.interactive(actor).authn["provider_scope"] == "tenant"

    for principal <- [agent, human] do
      {:ok, _} =
        AuthZ.create_permission_grant(%{
          principal_uid: principal.uid,
          resource_pattern: "tenant_console:pod_space",
          action: "update",
          condition: ~s(context.request.authn.provider_scope == "tenant")
        })
    end

    assert {:error, _} = AuthZ.authorize(actor, "tenant_console:pod_space", "update")
    assert :ok = AuthZ.authorize(Actor.interactive(actor), "tenant_console:pod_space", "update")
  end
end
