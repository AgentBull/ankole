defmodule Ankole.Principals.PodAdministrationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.{AuthZ, Principals}
  alias Ankole.AuthZ.Actor
  alias Ankole.IdentityProviders.DirectoryAccess
  alias Ankole.Principals.{HumanAccess, PodAdministration}

  test "recent authentication uses its expiry even when the issuing node clock is ahead" do
    principal = human_fixture().principal
    now = System.system_time(:second)

    for time <- [now + 1, now, now - 899] do
      assert :ok =
               Ankole.Authn.AddOns.SiteCredentialBinding.recent(
                 Actor.new(principal, authn: %{"authenticated_at" => time})
               )
    end

    assert {:error, :reauthentication_required} =
             Ankole.Authn.AddOns.SiteCredentialBinding.recent(
               Actor.new(principal, authn: %{"authenticated_at" => now - 901})
             )

    assert {:error, :reauthentication_required} =
             Ankole.Authn.AddOns.SiteCredentialBinding.recent(Actor.new(principal))
  end

  test "Pod restoration clears a provider suspension after current directory verification" do
    admin = human_fixture().principal
    member = human_fixture().principal

    assert {:ok, _} =
             HumanAccess.restrict_from_provider(member.uid, "lark", "suspended", "freeze")

    verify_healthy_directory(member.uid)

    assert {:ok, restored} =
             PodAdministration.restore(
               Actor.new(admin),
               member.uid,
               "reviewed"
             )

    assert restored.status == :active
    assert Enum.all?(HumanAccess.restrictions(member.uid), &is_struct(&1.cleared_at, DateTime))
    assert :ok = HumanAccess.check(member.uid, restored.access_version)
    assert {:error, :human_access_revoked} = HumanAccess.check(member.uid, member.access_version)
  end

  test "Pod restoration preserves all restrictions when provider evidence is missing or stale" do
    admin = human_fixture().principal
    member = human_fixture().principal

    assert {:ok, _} =
             PodAdministration.disable(Actor.new(admin), member.uid, :suspended, "review")

    assert {:ok, _} =
             HumanAccess.restrict_from_provider(member.uid, "lark", "suspended", "freeze")

    assert {:error, :provider_recovery_not_verified} =
             PodAdministration.restore(
               Actor.new(admin),
               member.uid,
               "reviewed"
             )

    assert Enum.all?(HumanAccess.restrictions(member.uid), &is_nil(&1.cleared_at))

    verify_healthy_directory(member.uid)
    assert {:ok, _} = DirectoryAccess.begin_sync("lark")

    assert {:error, :provider_recovery_not_verified} =
             PodAdministration.restore(
               Actor.new(admin),
               member.uid,
               "reviewed"
             )

    assert Enum.all?(HumanAccess.restrictions(member.uid), &is_nil(&1.cleared_at))
    assert {:ok, %{status: :disabled}} = Principals.get_principal(member.uid)
  end

  test "restoration requires permission to update the member" do
    editor = human_fixture().principal
    member = human_fixture().principal
    assert {:ok, _} = HumanAccess.disable(member.uid, "hold", nil, "disable")

    input =
      Ash.ActionInput.for_action(
        Ankole.Principals.PodAdminOperations,
        :restore_member,
        %{uid: member.uid, reason: "return"},
        tenant: Repo.tenant_id!()
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Ankole.Ash.run_action_authorized(input, Actor.new(editor))

    assert {:ok, %{status: :disabled}} = Principals.get_principal(member.uid)

    assert {:ok, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: editor.uid,
               resource_pattern: "tenant_console:principal:#{member.uid}",
               action: "update"
             })

    assert {:ok, %{ok: true}} = Ankole.Ash.run_action_authorized(input, Actor.new(editor))
    assert {:ok, %{status: :active}} = Principals.get_principal(member.uid)
  end

  test "principal editors cannot grant themselves Pod administration" do
    member = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: member.uid,
        resource_pattern: "tenant_console:principal:*",
        action: "update"
      })

    input =
      Ash.ActionInput.for_action(
        Ankole.Principals.PodAdminOperations,
        :set_admin,
        %{uid: member.uid, administrator: true},
        tenant: Repo.tenant_id!()
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Ankole.Ash.run_action_authorized(input, Actor.new(member))

    refute AuthZ.pod_admin?(member.uid)
    {:ok, _} = Repo.transact_top_level(fn -> Ankole.AuthZ.Root.ensure_pod_admin_group() end)

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: member.uid,
        resource_pattern: "tenant_console:group:pod_admin",
        action: "update"
      })

    assert {:ok, %{ok: true}} = Ankole.Ash.run_action_authorized(input, Actor.new(member))
    assert AuthZ.pod_admin?(member.uid)
  end

  test "an invitation does not change an existing guest's membership or consume a seat" do
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", true)
    member = human_fixture(%{membership: :guest, email: "guest@example.com"}).principal
    inviter = human_fixture().principal

    {:ok, created} =
      Principals.create_invitation(inviter.uid, %{
        kind: :link,
        invited_email: nil,
        membership: :member,
        expires_at: DateTime.add(DateTime.utc_now(), 3600),
        max_uses: 1
      })

    proof = %{
      provider_id: "email_otp",
      subject_id: "guest@example.com",
      verified_email: "guest@example.com",
      challenge_started_at: DateTime.utc_now()
    }

    assert {:ok, joined} =
             Repo.transact_top_level(fn ->
               Principals.accept_site_invitation_in_tx(created.invitation.id, proof)
             end)

    assert joined.uid == member.uid
    assert joined.membership == :guest
    assert Repo.get!(Ankole.Principals.Invitation, created.invitation.id).used_count == 0

    assert {:ok, joined} =
             Repo.transact_top_level(fn ->
               Principals.accept_site_invitation_in_tx(created.invitation.id, proof)
             end)

    assert joined.uid == member.uid
    assert Repo.get!(Ankole.Principals.Invitation, created.invitation.id).used_count == 0
  end

  test "provider editors need the selected provider's update and sync permissions" do
    member = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: member.uid,
        resource_pattern: "tenant_console:identity_provider:other-provider",
        action: "*"
      })

    save =
      Ash.ActionInput.for_action(
        Ankole.Principals.PodAdminOperations,
        :create_provider,
        %{
          provider_id: "lark-scope",
          adapter_id: "lark",
          config: %{
            "appID" => "cli_scoped",
            "appSecret" => "secret",
            "sync" => %{"contacts" => true}
          },
          enabled: true
        },
        tenant: Repo.tenant_id!()
      )

    sync =
      Ash.ActionInput.for_action(
        Ankole.Principals.PodAdminOperations,
        :sync_directory,
        %{provider_id: "lark-scope"},
        tenant: Repo.tenant_id!()
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Ankole.Ash.run_action_authorized(save, Actor.new(member))

    assert {:error, %Ash.Error.Forbidden{}} =
             Ankole.Ash.run_action_authorized(sync, Actor.new(member))

    for action <- ["update", "sync"] do
      {:ok, _} =
        AuthZ.create_permission_grant(%{
          principal_uid: member.uid,
          resource_pattern: "tenant_console:identity_provider:lark-scope",
          action: action
        })
    end

    assert {:ok, %{ok: true}} = Ankole.Ash.run_action_authorized(save, Actor.new(member))
    assert {:ok, _} = Ankole.IdentityProviders.fetch_active_provider("lark-scope")
    assert {:ok, %{ok: true}} = Ankole.Ash.run_action_authorized(sync, Actor.new(member))

    assert_enqueued(
      worker: Ankole.IdentityProviders.Jobs.SyncProvider,
      args: %{provider_id: "lark-scope"}
    )
  end

  test "a member cannot remove their last permitted login method" do
    member = human_fixture(%{email: "one@example.com"}).principal

    proof = %{
      provider_id: "email_otp",
      subject_id: "one@example.com",
      verified_email: "one@example.com"
    }

    {:ok, credential} =
      Repo.transact_top_level(fn -> Principals.bind_site_credential_in_tx(member.uid, proof) end)

    assert {:error, :last_login_method} = PodAdministration.unbind(member.uid, credential.id)
    assert Principals.site_credential_bound?(member.uid, "email_otp", "one@example.com")
  end

  test "the only SSO administrator cannot disable the Pod's last login provider" do
    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "lark-admin",
               "lark",
               %{"appID" => "cli_admin", "appSecret" => "secret"},
               true
             )

    assert {:ok, %{principal: admin}} =
             Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user("lark-admin", %{
               "user_id" => "admin"
             })

    {:ok, _} =
      Repo.transact_top_level(fn ->
        {:ok, group} = Ankole.AuthZ.Root.ensure_pod_admin_group()
        {:ok, _} = Ankole.AuthZ.Grants.upsert_pod_admin_grants(group)
        AuthZ.add_pod_admin_in_tx(admin.uid)
      end)

    assert {:error, :administrator_lockout} =
             Ankole.IdentityProviders.save_provider(
               "lark-admin",
               "lark",
               %{"appID" => "cli_admin", "appSecret" => "secret"},
               false
             )

    assert {:ok, _} = Ankole.IdentityProviders.fetch_active_provider("lark-admin")
  end

  test "member list uses a bounded number of queries for credentials and administrator roles" do
    members = for _ <- 1..20, do: human_fixture().principal

    {:ok, _} =
      Repo.transact_top_level(fn ->
        {:ok, group} = Ankole.AuthZ.Root.ensure_pod_admin_group()
        {:ok, _} = Ankole.AuthZ.Grants.upsert_pod_admin_grants(group)
        AuthZ.add_pod_admin_in_tx(hd(members).uid)
      end)

    parent = self()
    handler = "pod-members-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, meta, _ -> send(parent, {:member_query, meta.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    rows = PodAdministration.members()
    :telemetry.detach(handler)
    assert length(rows) == 20
    assert Enum.count(rows, & &1.administrator) == 1
    queries = collect_queries()
    assert Enum.any?(queries, &String.contains?(&1, "principal_site_credentials"))
    assert Enum.any?(queries, &String.contains?(&1, "principal_group_memberships"))
    assert length(queries) in 4..6
  end

  test "a Pod operator can recover an independently verified member when administrators have no login path",
       %{tenant: tenant} do
    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "lark-recovery",
               "lark",
               %{"appID" => "cli_recovery", "appSecret" => "secret"},
               true
             )

    assert {:ok, %{principal: member}} =
             Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user("lark-recovery", %{
               "user_id" => "verified"
             })

    assert {:ok, _} =
             HumanAccess.recover_pod_admin(
               tenant.id,
               member.uid,
               "operator",
               "verified with the enterprise"
             )

    assert AuthZ.pod_admin?(member.uid)

    assert [%{action: "operator_admin_recovery", details: %{"group" => "pod_admin"}}] =
             HumanAccess.history(member.uid)

    assert {:error, :active_admin_exists} =
             HumanAccess.recover_pod_admin(tenant.id, member.uid, "operator", "repeat")
  end

  test "mail invitation does not create a pending membership when SMTP is unavailable" do
    assert {:ok, _} = Ankole.Authn.Config.put_mail(nil)
    refute Ankole.Authn.Mailer.configured?()
    inviter = human_fixture().principal

    attrs = %{
      kind: :email,
      membership: :member,
      invited_email: "unavailable@example.com",
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      max_uses: 1
    }

    assert {:error, :mail_unavailable} =
             Ankole.Authn.AddOns.PodInvitation.call(
               :create,
               %{uid: inviter.uid, attrs: attrs, origin: "https://team.example.com"},
               []
             )

    assert Principals.list_invitations() == []
    assert Principals.pending_invitations(attrs.invited_email) == []
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:member_query, query} -> collect_queries([query | acc])
    after
      0 -> acc
    end
  end

  defp verify_healthy_directory(uid) do
    assert {:ok, ticket} = DirectoryAccess.begin_sync("lark")

    assert {:ok, _} =
             DirectoryAccess.finish_sync(ticket, "scope", [{uid, :healthy}],
               admission_scope: "none",
               maximum_removal_percent: 20
             )
  end
end
