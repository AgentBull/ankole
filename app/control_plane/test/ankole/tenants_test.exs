defmodule Ankole.TenantsTest do
  use Ankole.DataCase, async: false
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
    allow_cache_database_access()
    :ok = Tenants.ensure_scaffold(tenant)
    :ok
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
        %Group{}
        |> Group.changeset(%{name: "siteadmin", display_name: "Custom", kind: :static})
        |> Repo.insert!()

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

    assert Repo.get_by!(SiteConfig, scope: "global", key: key) == assignment
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
    assert {:ok, _} = Tenants.delete(renamed)
  end

  test "deleting an author tenant stops foreign work but preserves its author and history", %{
    tenant: first
  } do
    %{principal: author} = human_fixture()
    second = new_tenant()
    third = new_tenant()
    %{principal: unrelated_author} = Repo.with_tenant(third.id, fn -> human_fixture() end)
    %{principal: next_admin} = Repo.with_tenant(second.id, fn -> human_fixture() end)
    assert {:ok, _} = Tenants.transfer_site_administration(second, next_admin.uid)

    {event, cron} =
      Repo.with_tenant(second.id, fn ->
        %{principal: agent} = agent_fixture(%{owner_principal_uid: next_admin.uid})

        conversation =
          Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid, binding_name: "test")

        {:ok, event} =
          Repo.transact(fn repo ->
            Ankole.Signals.accept_in_tx(repo, %{
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
      assert persisted.input_state == "dead_letter"
      assert persisted.human_uid == author.uid
      assert persisted.authorization_kind == "human"

      assert {:error, :human_access_revoked} =
               Repo.transact(fn repo -> WorkAccess.check_in_tx(repo, persisted) end)

      review = WorkAccess.list_unresolved()

      assert %{human_uid: author_uid, can_reauthorize: true, status: "paused"} =
               Enum.find(review, &(&1.id == cron.id))

      assert author_uid == author.uid
      assert %{can_reauthorize: false} = Enum.find(review, &(&1.id == event.id))
      ref = Ankole.ActorRef.from_principal(next_admin)

      assert {:error, :work_review_changed} =
               WorkAccess.classify("cron", cron.id, nil, ref, "Cannot remove Human dependency")

      assert {:error, :work_review_changed} =
               WorkAccess.classify(
                 "cron",
                 cron.id,
                 unrelated_author.uid,
                 ref,
                 "Cannot assign another tenant's person"
               )

      assert {:error, :work_review_changed} =
               WorkAccess.classify(
                 "signal",
                 event.id,
                 next_admin.uid,
                 ref,
                 "Rebuild required"
               )

      assert {:ok, %{status: "paused"}} =
               WorkAccess.classify(
                 "cron",
                 cron.id,
                 next_admin.uid,
                 ref,
                 "Reviewed replacement authority"
               )

      assert Enum.any?(HumanAccess.history(next_admin.uid), fn audit ->
               audit.action == "classify_work" and
                 audit.details["previous_authorization"]["human_uid"] == author.uid and
                 audit.details["previous_authorization"]["human_access_version"] ==
                   author.access_version
             end)

      assert {:error, :work_review_changed} =
               WorkAccess.classify("cron", cron.id, nil, ref, "Already authorized")

      assert {:ok, %{status: "active"}} = Ankole.Schedule.resume_cron_schedule(cron.id)
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

    {:ok, review} = AuthZ.restoration_review(human.uid)

    {:ok, restored} =
      HumanAccess.restore(human.uid, review.fingerprint, nil, "verified", Ecto.UUID.generate())

    {:ok, event} =
      Repo.transact(fn repo ->
        Ankole.Signals.accept_in_tx(repo, %{
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
    assert Repo.get!(Signal, event.id).input_state == "open"

    {:ok, revoked_again} =
      HumanAccess.disable(human.uid, "review again", nil, Ecto.UUID.generate())

    assert [%{uid: uid}] = Ankole.Principals.WorkCleanup.pending_for_tenant(50)
    assert uid == human.uid

    assert {:ok, _} =
             Ankole.Principals.WorkCleanup.cleanup(human.uid, revoked_again.access_version)

    assert Repo.get!(Signal, event.id).input_state == "dead_letter"
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

      {:ok, review} = AuthZ.restoration_review(human.uid)

      assert {:ok, %{status: :active}} =
               HumanAccess.restore(
                 human.uid,
                 review.fingerprint,
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

      {:ok, review} = AuthZ.restoration_review(human.uid)
      {:ok, _} = Tenants.delete(tenant)

      assert {:error, :tenant_deleting} =
               HumanAccess.restore(
                 human.uid,
                 review.fingerprint,
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

    client =
      %Client{}
      |> Client.changeset(%{
        name: "Logout test",
        client_type: :public,
        redirect_uris: ["https://example.test/callback"],
        backchannel_logout_uri: "https://example.test/logout"
      })
      |> Repo.insert!()

    %Session{}
    |> Ecto.Changeset.change(%{
      client_id: client.id,
      principal_uid: human.uid,
      browser_id: browser.id,
      access_version: human.access_version,
      provider_id: "local",
      auth_time: System.system_time(:second),
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    })
    |> Repo.insert!()
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
      %Tenants.Tenant{}
      |> Tenants.Tenant.changeset(%{
        slug: "deletion-race-#{Ecto.UUID.generate()}",
        display_name: "Deletion race"
      })
      |> Repo.insert!()

    :ok = Tenants.ensure_scaffold(tenant)

    on_exit(fn ->
      if match?({:ok, _}, Tenants.get(tenant.id)) do
        {:ok, _} = Tenants.delete(tenant)
        drain_delete(tenant.id)
      end

      Repo.delete_all(
        from job in Oban.Job,
          where: fragment("?->>'tenant_id' = ?", job.args, ^tenant.id)
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
          Repo.transact(fn _repo ->
            {:ok, result} = Principals.create_human(%{display_name: "Admitted before deletion"})
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
               Repo.get!(Ankole.Principals.Principal, uid).status
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
