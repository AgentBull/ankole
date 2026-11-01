defmodule Ankole.TenantsTest do
  use Ankole.DataCase, async: false
  import ExUnit.CaptureLog
  import Ankole.PrincipalsFixtures

  alias Ankole.{AppConfigure, AuthZ, BrowserSessions, Tenants}
  alias Ankole.AuthZ.Group
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.LogoutDelivery
  alias Ankole.OIDC.Session
  alias Ankole.Principals.HumanAccess
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers.WorkerEnv

  setup %{tenant: tenant} do
    :ok = set_privileged_tenant(tenant)
    :ok = Tenants.ensure_scaffold(tenant)
    :ok
  end

  test "profile persistence cannot set lifecycle markers", %{tenant: tenant} do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(tenant, :profile_in_tx, %{
                 suspended_at: DateTime.utc_now(),
                 deleting_at: DateTime.utc_now()
               })
             end)

    assert Enum.sort(
             Enum.map(errors, fn %Ash.Error.Invalid.NoSuchInput{input: field} -> field end)
           ) == [:deleting_at, :suspended_at]

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Tenants.Tenant, tenant.id), tenant)
  end

  test "final persistence requires deletion and repeated requests retain its first time" do
    tenant = new_tenant()

    assert {:error, error} =
             Repo.transact(fn _repo -> Ankole.Ash.destroy(tenant, :delete_in_tx) end)

    assert %{deleting_at: [_]} = errors_on(error)
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Tenants.Tenant, tenant.id), tenant)

    assert {:ok, first} = Tenants.delete(tenant)
    assert {:ok, repeated} = Tenants.delete(tenant)
    assert repeated.deleting_at == first.deleting_at
    assert {:error, :tenant_deleting} = Tenants.resume(repeated)
    assert {:error, :tenant_deleting} = Tenants.update(repeated, %{display_name: "Changed"})
    assert Repo.get!(Tenants.Tenant, tenant.id).display_name == tenant.display_name
  end

  test "tenant deletion revokes its final Pod administrator and finishes" do
    tenant = new_tenant()

    Repo.with_tenant(tenant.id, fn ->
      admin = human_fixture().principal
      assert {:ok, _} = AuthZ.add_principal_to_group(admin.uid, "pod_admin")

      assert {:error, :last_active_human_admin} =
               HumanAccess.disable(admin.uid, "suspend", nil, Ecto.UUID.generate(), :suspended)
    end)

    assert {:ok, _} = Tenants.delete(tenant)
    drain_delete(tenant.id)
    assert {:error, :not_found} = Tenants.get(tenant.id)
  end

  test "tenant deletion advances past slow empty tables" do
    tenant = new_tenant()

    # A statement trigger also runs when the table has no matching rows. Keep
    # the first empty-table check slower than the deletion job's time slice.
    Repo.query!("""
    CREATE FUNCTION test_slow_empty_tenant_batch() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_sleep(1.1);
      RETURN NULL;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER test_slow_empty_tenant_batch BEFORE DELETE ON base_records
    FOR EACH STATEMENT EXECUTE FUNCTION test_slow_empty_tenant_batch()
    """)

    cleanup_tenant!(tenant)
    assert {:error, :not_found} = Tenants.get(tenant.id)
  end

  test "tenant deletion removes nested ACL anchors across multiple leaf batches" do
    tenant = new_tenant()

    Repo.with_tenant(tenant.id, fn ->
      admin = human_fixture().principal
      {:ok, root} = Ankole.Files.Nodes.private_root(admin.uid)

      assert {:ok, _} =
               Repo.transact_top_level(fn ->
                 {:ok, outer} =
                   Ankole.Files.Nodes.create_in_tx(%{
                     parent_id: root.id,
                     kind: :folder,
                     name: "outer",
                     has_local_acl: true
                   })

                 {:ok, passthrough} =
                   Ankole.Files.Nodes.create_in_tx(%{
                     parent_id: outer.id,
                     kind: :folder,
                     name: "pass-through"
                   })

                 {:ok, inner} =
                   Ankole.Files.Nodes.create_in_tx(%{
                     parent_id: passthrough.id,
                     kind: :folder,
                     name: "inner",
                     has_local_acl: true
                   })

                 {:ok, leaf_parent} =
                   Ankole.Files.Nodes.create_in_tx(%{
                     parent_id: inner.id,
                     kind: :folder,
                     name: "leaf-parent"
                   })

                 # The tenant lifecycle deletes 200 leaves per transaction. Both
                 # anchors must survive until every referring leaf has been removed.
                 Repo.query!(
                   """
                   INSERT INTO drive_nodes(tenant_id,id,parent_id,kind,name,acl_anchor_id)
                   SELECT $1::text::uuid,gen_random_uuid(),$2::text::uuid,'file',
                     'file-' || i,$3::text::uuid FROM generate_series(1,401) AS i
                   """,
                   [tenant.id, leaf_parent.id, inner.id]
                 )

                 {:ok, inner}
               end)
    end)

    assert {:ok, _} = Tenants.delete(tenant)
    drain_delete(tenant.id)
    assert {:error, :not_found} = Tenants.get(tenant.id)
  end

  test "active slug lookup follows durable lifecycle state without selecting a tenant", %{
    tenant: selected
  } do
    tenant = new_tenant()
    id = tenant.id

    Repo.without_tenant(fn ->
      assert {:ok, %{id: ^id}} = Tenants.active_by_slug(tenant.slug)
      assert Tenants.accepting_work?(tenant)
      assert Tenants.accepting_work?(id)
      assert {:error, :not_found} = Tenants.active_by_slug(" " <> tenant.slug)
      assert {:error, :not_found} = Tenants.active_by_slug("missing-#{Ecto.UUID.generate()}")
      refute Tenants.accepting_work?(Ecto.UUID.generate())

      assert {:ok, suspended} = Tenants.suspend(tenant)
      assert {:error, :not_found} = Tenants.active_by_slug(tenant.slug)
      refute Tenants.accepting_work?(suspended)
      refute Tenants.accepting_work?(id)
      assert {:ok, %{id: ^id}} = Tenants.get(id)

      assert {:ok, resumed} = Tenants.resume(suspended)
      assert {:ok, %{id: ^id}} = Tenants.active_by_slug(tenant.slug)
      assert {:ok, deleting} = Tenants.delete(resumed)
      assert {:error, :not_found} = Tenants.active_by_slug(tenant.slug)
      refute Tenants.accepting_work?(deleting)
      refute Tenants.accepting_work?(id)
      assert {:ok, %{id: ^id}} = Tenants.get(id)
      assert Repo.tenant_id() == nil
    end)

    assert Repo.tenant_id!() == selected.id
  end

  test "inbound dispatch runs only while the tenant accepts work", %{tenant: tenant} do
    assert :processed = Tenants.dispatch_inbound(fn -> :processed end)
    Repo.update!(Ecto.Changeset.change(tenant, suspended_at: DateTime.utc_now()))

    assert {:ok, []} =
             Tenants.dispatch_inbound(fn -> flunk("suspended ingress reached its adapter") end)
  end

  test "site fanout preserves other tenants' work after one tenant raises", %{tenant: original} do
    broken = new_tenant()
    healthy = new_tenant()

    results =
      Repo.without_tenant(fn ->
        Tenants.map_active(fn ->
          if Repo.tenant_id!() == broken.id, do: raise("broken provider")
          {:ok, Repo.tenant_id!()}
        end)
      end)

    assert {broken.id, {:error, {:exception, "broken provider"}}} in results
    assert {healthy.id, {:ok, healthy.id}} in results
    assert Repo.tenant_id!() == original.id
  end

  test "fanout logs keep failure classes without exposing returned or raised private data", %{
    tenant: original
  } do
    raised = new_tenant()
    thrown = new_tenant()
    returned = new_tenant()
    healthy = new_tenant()
    secret = "private-fanout-request-credential"

    {results, log} =
      with_log(
        [format: "$metadata$message\n", metadata: :all],
        fn ->
          Repo.without_tenant(fn ->
            Tenants.map_active(fn ->
              cond do
                Repo.tenant_id!() == raised.id -> raise_private_fanout_error(secret)
                Repo.tenant_id!() == thrown.id -> throw(secret)
                Repo.tenant_id!() == returned.id -> {:error, %{credential: secret}}
                true -> {:ok, Repo.tenant_id!()}
              end
            end)
          end)
        end
      )

    raised_id = raised.id

    assert {^raised_id, {:error, {:exception, raised_message}}} =
             List.keyfind(results, raised.id, 0)

    assert raised_message =~ secret
    assert {thrown.id, {:error, {:throw, secret}}} in results
    assert {returned.id, {:error, %{credential: secret}}} in results
    assert {healthy.id, {:ok, healthy.id}} in results
    assert Repo.tenant_id!() == original.id

    assert length(Regex.scan(~r/event=tenants\.site_fanout_failed/, log)) == 3
    assert log =~ "failure=Elixir.ArgumentError"
    assert log =~ "failure=throw"
    assert log =~ "failure=Elixir.ErlangError"
    assert log =~ ":erlang.binary_to_integer/1"
    refute log =~ secret
  end

  defp raise_private_fanout_error(secret) do
    :erlang.binary_to_integer(secret)
  rescue
    error in ArgumentError ->
      reraise %{error | message: secret <> ": " <> Exception.message(error)}, __STACKTRACE__
  end

  test "retention fanout includes suspended and deleting tenants", %{tenant: original} do
    suspended = new_tenant()
    deleting = new_tenant()
    Repo.update!(Ecto.Changeset.change(suspended, suspended_at: DateTime.utc_now()))
    Repo.update!(Ecto.Changeset.change(deleting, deleting_at: DateTime.utc_now()))
    results = Tenants.map_all(fn -> {:ok, Repo.tenant_id!()} end)
    assert {suspended.id, {:ok, suspended.id}} in results
    assert {deleting.id, {:ok, deleting.id}} in results
    assert Repo.tenant_id!() == original.id
  end

  test "configuration and shell variables inherit site then tenant then the selected Agent", %{
    tenant: tenant
  } do
    %{principal: first} = agent_fixture()
    other = new_tenant()
    %{principal: second} = Repo.with_tenant(other.id, fn -> agent_fixture() end)
    key = "__test.tenant.#{Ecto.UUID.generate()}"

    definition =
      AppConfigure.define(
        key: key,
        scope: :tenant,
        encrypted: false,
        schema: Ankole.AppConfigure.Schema.non_empty_string(),
        default_value: "default"
      )

    :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    assert {:ok, "site"} = AppConfigure.put_global(definition, "site")
    assert {:ok, "tenant"} = AppConfigure.put_tenant_by_key(key, "tenant")
    assert {:ok, %{value: "tenant", source: :tenant}} = AppConfigure.resolve(definition)

    assert {:ok, %{value: "site", source: :global}} =
             AppConfigure.resolve(definition, scope: :global)

    Repo.with_tenant(other.id, fn ->
      assert {:ok, "site"} = AppConfigure.get(definition)

      assert {:ok, "other tenant"} =
               AppConfigure.put_tenant_by_key(definition.key, "other tenant")

      assert {:ok, "other tenant"} = AppConfigure.get(definition)
    end)

    name = "TENANCY_TEST_#{System.unique_integer([:positive])}"
    assert {:ok, _} = WorkerEnv.console_put_global(name, %{"value" => "site", "secret" => false})

    assert {:ok, _} =
             WorkerEnv.console_put_tenant(name, %{"value" => "tenant", "secret" => false})

    assert {:ok, _} =
             WorkerEnv.console_put_for_agent(first.uid, name, %{
               "value" => "agent",
               "secret" => false
             })

    assert %{source: "agent", value: "agent"} =
             listed(WorkerEnv.console_list_for_agent(first.uid), name)

    assert %{source: "tenant", value: "tenant"} = listed(WorkerEnv.console_list_tenant(), name)
    assert %{source: "global", value: "site"} = listed(WorkerEnv.console_list_global(), name)

    Repo.with_tenant(other.id, fn ->
      assert %{source: "global", value: "site"} =
               listed(WorkerEnv.console_list_for_agent(second.uid), name)
    end)

    secret_name = name <> "_SECRET"

    assert {:ok, _} =
             WorkerEnv.console_put_global(secret_name, %{
               "value" => "stored-secret",
               "secret" => true
             })

    assert {:ok, _} =
             WorkerEnv.console_put_tenant(secret_name, %{"description" => "Tenant override"})

    assert {:ok, "stored-secret"} = WorkerEnv.console_decrypt_tenant(secret_name)

    assert {:ok, _} =
             WorkerEnv.console_put_for_agent(first.uid, secret_name, %{
               "description" => "Agent override"
             })

    assert {:ok, "stored-secret"} = WorkerEnv.console_decrypt_for_agent(first.uid, secret_name)
    assert %{description: nil} = listed(WorkerEnv.console_list_global(), secret_name)
    assert Repo.tenant_id!() == tenant.id
  end

  test "administration transfer requires another tenant and keeps one protected admin tenant", %{
    tenant: first
  } do
    %{principal: first_admin} = human_fixture()
    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(first_admin.uid)
    second = new_tenant()
    %{principal: second_admin} = Repo.with_tenant(second.id, fn -> human_fixture() end)
    assert {:error, :privileged_tenant_protected} = Tenants.suspend(first)
    assert {:error, :privileged_tenant_protected} = Tenants.delete(first)
    assert {:ok, _} = Tenants.transfer_site_administration(second, second_admin.uid)

    assert {:error, :privileged_tenant_protected} =
             Tenants.transfer_site_administration(second, second_admin.uid)

    refute Repo.get_by(Group, name: "siteadmin")
    refute AuthZ.site_admin?(first_admin.uid)
    assert AuthZ.site_admin?(second_admin.uid)
    assert Repo.tenant_id!() == first.id

    Repo.with_tenant(second.id, fn ->
      assert {:error, :last_active_human_admin} =
               HumanAccess.disable(
                 second_admin.uid,
                 "review",
                 Ankole.ActorRef.from_principal(first_admin),
                 Ecto.UUID.generate()
               )
    end)

    assert {:ok, renamed} = Tenants.update(second, %{slug: "renamed-#{Ecto.UUID.generate()}"})
    assert {:ok, %{id: id}} = Tenants.privileged()
    assert id == renamed.id
    assert {:error, :privileged_tenant_protected} = Tenants.delete(renamed)
  end

  test "a conflicting target group cannot partly move site administration", %{tenant: first} do
    second = new_tenant()

    %{principal: human} =
      Repo.with_tenant(second.id, fn ->
        {:ok, _group} =
          AuthZ.create_principal_group(%{
            name: "siteadmin",
            display_name: "Custom",
            kind: :static
          })

        human_fixture()
      end)

    assert {:error, :group_name_taken} = Tenants.transfer_site_administration(second, human.uid)
    assert {:ok, %{id: id}} = Tenants.privileged()
    assert id == first.id
  end

  test "renaming the privileged tenant leaves its assignment unchanged when another tenant reuses the slug",
       %{
         tenant: privileged
       } do
    alias Ankole.AppConfigure.SiteConfig
    key = "tenants.privileged_tenant_id"
    assignment = Repo.get_by!(SiteConfig, scope: "global", key: key)
    %{principal: administrator} = human_fixture()
    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(administrator.uid)

    assert {:ok, renamed} =
             Tenants.update(privileged, %{slug: "renamed-#{Ecto.UUID.generate()}"})

    Ankole.DataCase.assert_persisted_equal(
      Repo.get_by!(SiteConfig, scope: "global", key: key),
      assignment
    )

    refute Repo.get_by(SiteConfig, scope: "global", key: "tenants.privileged_slug")
    assert {:ok, %{id: id}} = Tenants.privileged()
    assert id == renamed.id

    assert {:ok, reused} = Tenants.create(%{slug: privileged.slug, display_name: "Reused slug"})
    assert {:ok, _} = Tenants.suspend(reused)
    assert {:error, :privileged_tenant_protected} = Tenants.suspend(renamed)
    assert {:error, :privileged_tenant_protected} = Tenants.delete(renamed)
    assert AuthZ.site_admin?(administrator.uid)

    target = new_tenant()
    %{principal: next_administrator} = Repo.with_tenant(target.id, fn -> human_fixture() end)
    assert {:ok, _} = Tenants.transfer_site_administration(target, next_administrator.uid)
    refute Repo.get_by(Group, name: "siteadmin")
    refute AuthZ.site_admin?(administrator.uid)
    assert AuthZ.site_admin?(next_administrator.uid)
    assert Repo.with_tenant(target.id, fn -> AuthZ.pod_admin?(next_administrator.uid) end)
    assert {:ok, _} = Tenants.delete(renamed)
  end

  test "deleting another tenant preserves local work and complete foreign audit attribution", %{
    tenant: first
  } do
    %{principal: author} = human_fixture()
    second = new_tenant()
    Repo.with_tenant(second.id, fn -> human_fixture(%{email: author.uid}) end)
    %{principal: next_admin} = Repo.with_tenant(second.id, fn -> human_fixture() end)
    assert {:ok, _} = Tenants.transfer_site_administration(second, next_admin.uid)

    {event, cron} =
      Repo.with_tenant(second.id, fn ->
        %{principal: agent} = agent_fixture(%{owner_principal_uid: next_admin.uid})

        conversation =
          Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid, binding_name: "test")

        {:ok, event} =
          Repo.transact(fn ->
            Ankole.Signals.accept_in_tx(%{
              target: %{agent_uid: agent.uid, session_id: "test:tenant-delete"},
              sender: author.uid,
              source: "test://tenant-delete",
              id: Ecto.UUID.generate(),
              type: "test.work",
              time: DateTime.utc_now(),
              data: %{}
            })
          end)

        now = DateTime.utc_now(:microsecond)

        {:ok, %{cron_schedule: cron}} =
          Ankole.Schedule.create_cron_schedule(
            %{
              "agent_uid" => agent.uid,
              "owner_session_id" => "test:tenant-delete",
              "binding_name" => "test",
              "name" => "Authorized routine",
              "idempotency_key" => Ecto.UUID.generate(),
              "schedule" => %{
                "kind" => "every",
                "every_ms" => 60_000,
                "anchor_at" => DateTime.to_iso8601(DateTime.add(now, 60))
              },
              "payload" => %{"task" => "Continue the routine"},
              "delivery" => %{
                "targets" => [
                  %{"binding_name" => "test", "conversation_id" => conversation.conversation_id}
                ]
              }
            },
            now: now,
            authorization: WorkAccess.from_sender(author.uid),
            created_by: %{"principal_uid" => to_string(Ankole.ActorRef.from_principal(author))}
          )

        refute Enum.any?(WorkAccess.list_unresolved(), &(&1.id == cron.id))
        {event, cron}
      end)

    assert {:ok, _} = Tenants.delete(first)
    drain_delete(first.id)
    assert {:error, :not_found} = Tenants.get(first.id)

    Repo.with_tenant(second.id, fn ->
      persisted = Repo.get!(Signal, event.id)
      assert persisted.status == event.status
      assert persisted.human_uid == author.uid
      assert persisted.authorization_kind == "human"
      assert {:ok, :ok} = Repo.transact(fn -> {:ok, WorkAccess.check_in_tx(persisted)} end)
      assert {:ok, local} = Ankole.Principals.get_principal(author.uid)
      assert local.tenant_id == second.id
      refute Enum.any?(WorkAccess.list_unresolved(), &(&1.id in [event.id, cron.id]))
      saved = Repo.get!(Ankole.Schedule.Schemas.CronSchedule, cron.id)
      assert saved.status == :active

      assert saved.created_by["principal_uid"] ==
               to_string(Ankole.ActorRef.from_principal(author))
    end)
  end

  test "clientless logout confirmation ends only its verified browser sessions across tenants", %{
    tenant: first
  } do
    second = new_tenant()
    {:ok, browser} = BrowserSessions.create()
    {:ok, other_browser} = BrowserSessions.create()
    first_session = oidc_session(browser)
    second_session = Repo.with_tenant(second.id, fn -> oidc_session(browser) end)
    unrelated = Repo.with_tenant(second.id, fn -> oidc_session(other_browser) end)
    ref = BrowserSessions.reference(browser)
    assert {:ok, request} = Repo.without_tenant(fn -> Ankole.OIDC.RPLogout.prepare(ref, %{}) end)

    assert {:ok, _} =
             Repo.without_tenant(fn -> Ankole.OIDC.RPLogout.confirmation(ref, request.id) end)

    assert {:ok, _} = Repo.without_tenant(fn -> Ankole.OIDC.RPLogout.confirm(ref, request.id) end)
    assert Repo.tenant_id!() == first.id
    assert Repo.get!(Session, first_session.id).ended_at

    Repo.with_tenant(second.id, fn ->
      assert Repo.get!(Session, second_session.id).ended_at
      refute Repo.get!(Session, unrelated.id).ended_at
      delivery = Repo.get_by!(LogoutDelivery, session_id: second_session.id)

      assert_enqueued(
        worker: Ankole.OIDC.LogoutWorker,
        args: %{delivery_id: delivery.id, tenant_id: second.id}
      )
    end)

    assert {:ok, _} = BrowserSessions.logout(BrowserSessions.reference(browser))
    assert nil == BrowserSessions.current_reference(BrowserSessions.reference(browser))
  end

  test "cleanup completion is idempotent per revocation and an old retry preserves newly authorized work" do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture()
    {:ok, disabled} = HumanAccess.disable(human.uid, "review", nil, Ecto.UUID.generate())
    assert {:ok, _} = Ankole.Principals.WorkCleanup.cleanup(human.uid, disabled.access_version)
    assert {:ok, _} = Ankole.Principals.WorkCleanup.cleanup(human.uid, disabled.access_version)
    assert [] = Ankole.Principals.WorkCleanup.pending_for_tenant(50)
    assert 1 == Enum.count(HumanAccess.history(human.uid), &(&1.source == "work_cleanup"))

    [restriction] = HumanAccess.restrictions(human.uid)

    {:ok, _} =
      HumanAccess.clear_restriction(
        human.uid,
        restriction.id,
        nil,
        "verified",
        Ecto.UUID.generate()
      )

    {:ok, restored} =
      HumanAccess.restore(human.uid, nil, "verified", Ecto.UUID.generate())

    {:ok, event} =
      Repo.transact(fn ->
        Ankole.Signals.accept_in_tx(%{
          target: %{agent_uid: agent.uid, session_id: "test:cleanup-retry"},
          sender: restored.uid,
          source: "test://cleanup-retry",
          id: Ecto.UUID.generate(),
          type: "test.work",
          time: DateTime.utc_now(),
          data: %{}
        })
      end)

    assert {:ok, _} = Ankole.Principals.WorkCleanup.cleanup(human.uid, disabled.access_version)
    assert Repo.get!(Signal, event.id).status == :queued

    {:ok, revoked_again} =
      HumanAccess.disable(human.uid, "review again", nil, Ecto.UUID.generate())

    assert [%{uid: uid}] = Ankole.Principals.WorkCleanup.pending_for_tenant(50)
    assert uid == human.uid

    assert {:ok, _} =
             Ankole.Principals.WorkCleanup.cleanup(human.uid, revoked_again.access_version)

    assert Repo.get!(Signal, event.id).status == :dead_letter
    assert 2 == Enum.count(HumanAccess.history(human.uid), &(&1.source == "work_cleanup"))
  end

  test "Human restoration remains available while suspended but is refused during deletion" do
    tenant = new_tenant()

    Repo.with_tenant(tenant.id, fn ->
      %{principal: human} = human_fixture()
      {:ok, _} = Tenants.suspend(tenant)
      {:ok, _} = HumanAccess.disable(human.uid, "review", nil, Ecto.UUID.generate())
      [restriction] = HumanAccess.restrictions(human.uid)

      {:ok, _} =
        HumanAccess.clear_restriction(
          human.uid,
          restriction.id,
          nil,
          "verified",
          Ecto.UUID.generate()
        )

      assert {:ok, %{status: :active}} =
               HumanAccess.restore(
                 human.uid,
                 nil,
                 "verified",
                 Ecto.UUID.generate()
               )

      {:ok, _} = HumanAccess.disable(human.uid, "review again", nil, Ecto.UUID.generate())
      restriction = Enum.find(HumanAccess.restrictions(human.uid), &is_nil(&1.cleared_at))

      {:ok, _} =
        HumanAccess.clear_restriction(
          human.uid,
          restriction.id,
          nil,
          "verified",
          Ecto.UUID.generate()
        )

      {:ok, _} = Tenants.delete(tenant)

      assert {:error, :tenant_deleting} =
               HumanAccess.restore(
                 human.uid,
                 nil,
                 "verified",
                 Ecto.UUID.generate()
               )
    end)
  end

  defp new_tenant do
    {:ok, tenant} =
      Tenants.create(%{slug: "tenant-#{Ecto.UUID.generate()}", display_name: "Other"})

    tenant
  end

  defp drain_delete(id) do
    result =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        case Repo.without_tenant(fn ->
               Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => id}})
             end) do
          :ok -> {:halt, :ok}
          {:snooze, _} -> {:cont, :pending}
          error -> flunk("tenant deletion failed: #{inspect(error)}")
        end
      end)

    assert result == :ok
  end

  defp oidc_session(browser) do
    %{principal: human} = human_fixture()

    {:ok, client} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(Client, :create_in_tx, %{
          name: "Logout test",
          client_type: :public,
          redirect_uris: ["https://example.test/callback"],
          backchannel_logout_uri: "https://example.test/logout"
        })
      end)

    {:ok, session} =
      Ankole.OIDCFixtures.session(human.uid, client.id, "openid", browser: browser)

    session
  end

  defp listed({:ok, items}, name), do: Enum.find(items, &(&1.name == name))
end

defmodule Ankole.TenantDeletionConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ankole.{Principals, Repo, Tenants}
  alias Ankole.Tenants.Jobs.Delete

  setup do
    Ankole.DataCase.setup_sandbox(%{sandbox: false})

    tenant =
      Ankole.DataCase.create_committed_tenant(%{
        slug: "deletion-race-#{Ecto.UUID.generate()}",
        display_name: "Deletion race"
      })

    on_exit(fn ->
      if match?({:ok, _}, Tenants.get(tenant.id)) do
        {:ok, _} = Tenants.delete(tenant)
        drain_delete(tenant.id)
      end

      Repo.delete_all(
        from(job in Oban.Job,
          where: fragment("?->>'tenant_id' = ?", job.args, ^tenant.id)
        )
      )
    end)

    {:ok, tenant: tenant}
  end

  test "final deletion waits for an admitted Human write and then returns it to cleanup", %{
    tenant: tenant
  } do
    {:ok, _} = Tenants.delete(tenant)
    parent = self()

    creator =
      Task.async(fn ->
        Repo.with_tenant(tenant.id, fn ->
          Repo.transact(fn ->
            {:ok, result} =
              Principals.create_human_in_tx(%{
                display_name: "Admitted before deletion",
                email: "admitted@example.com"
              })

            send(parent, {:human_inserted, result.principal.uid})
            receive do: (:commit -> {:ok, result})
          end)
        end)
      end)

    assert_receive {:human_inserted, uid}, 5_000

    deleter =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
          send(parent, {:deletion_connection, backend_pid})
          delete_step(tenant.id)
        end)
      end)

    try do
      assert_receive {:deletion_connection, backend_pid}, 5_000
      assert_waiting_for_lock(backend_pid, 200)
      send(creator.pid, :commit)
      assert {:ok, _} = Task.await(creator)
      assert {:snooze, 1} = Task.await(deleter)
      assert {:ok, _} = Tenants.get(tenant.id)

      assert Repo.with_tenant(tenant.id, fn ->
               Repo.get_by!(Ankole.Principals.Principal, uid: uid).status
             end) == :active

      drain_delete(tenant.id)
      assert {:error, :not_found} = Tenants.get(tenant.id)
    after
      send(creator.pid, :commit)
      Task.shutdown(creator, :brutal_kill)
      Task.shutdown(deleter, :brutal_kill)
    end
  end

  defp assert_waiting_for_lock(_pid, 0),
    do: flunk("tenant deletion did not wait for the concurrent tenant foreign-key lock")

  defp assert_waiting_for_lock(pid, remaining) do
    %{rows: [[waiting]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1 AND NOT granted)",
        [pid]
      )

    unless waiting do
      Process.sleep(10)
      assert_waiting_for_lock(pid, remaining - 1)
    end
  end

  defp delete_step(id),
    do: Repo.without_tenant(fn -> Delete.run(%Oban.Job{args: %{"tenant_id" => id}}) end)

  defp drain_delete(id) do
    assert Enum.reduce_while(1..100, :pending, fn _, _ ->
             case delete_step(id) do
               :ok -> {:halt, :ok}
               {:snooze, _} -> {:cont, :pending}
               error -> flunk("tenant deletion failed: #{inspect(error)}")
             end
           end) == :ok
  end
end
