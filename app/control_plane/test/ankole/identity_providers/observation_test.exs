defmodule Ankole.IdentityProviders.ObservationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Membership
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.{Directory, Login}
  alias Ankole.Principals.{HumanUser, Principal}

  setup do
    original_registry = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, wecom} = Ankole.Plugins.Spec.from_module(Ankole.Plugins.WeComAdapter)

    Ankole.Plugins.Registry.update_for_test(fn state ->
      %{state | active: Map.put(state.active, wecom.id, wecom)}
    end)

    on_exit(fn -> Ankole.Plugins.Registry.update_for_test(fn _ -> original_registry end) end)
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
    assert {:ok, _} = Ankole.Plugins.put_configured_enabled("wecom-adapter", true)
    Ankole.AppConfigure.Registry.clear_for_test()
    :ok
  end

  test "OIDC invitation rejects an unrelated identity before any member is committed" do
    admin = Ankole.PrincipalsFixtures.human_fixture().principal
    assert {:ok, _} = IdentityProviders.save_provider("lark-invite", "lark", config("lark"))

    assert {:ok, created} =
             Ankole.Principals.create_invitation(admin.uid, %{
               kind: :email,
               invited_email: "invited@example.com",
               membership: :member,
               expires_at: DateTime.add(DateTime.utc_now(), 3600),
               max_uses: 1
             })

    stub_login("lark", :error)
    count = Repo.aggregate(Principal, :count)

    assert {:error, :invitation_identity_mismatch} =
             Login.complete_oidc_login("lark-invite", "code",
               invitation_id: created.invitation.id
             )

    assert Repo.aggregate(Principal, :count) == count

    assert {:error, :not_found} =
             Ankole.Principals.resolve_platform_subject_uid("lark-invite", "employee-1")

    assert Repo.get!(Ankole.Principals.Invitation, created.invitation.id).used_count == 0
  end

  test "failed login completion rolls back a new invited member and its invitation use" do
    admin = Ankole.PrincipalsFixtures.human_fixture().principal
    assert {:ok, _} = IdentityProviders.save_provider("lark-invite", "lark", config("lark"))

    assert {:ok, created} =
             Ankole.Principals.create_invitation(admin.uid, %{
               kind: :link,
               invited_email: nil,
               membership: :member,
               expires_at: DateTime.add(DateTime.utc_now(), 3600),
               max_uses: 1
             })

    stub_login("lark", :error)
    count = Repo.aggregate(Principal, :count)

    assert {:error, :login_expired} =
             Login.complete_oidc_login("lark-invite", "code",
               invitation_id: created.invitation.id,
               complete: fn _ -> {:error, :login_expired} end
             )

    assert Repo.aggregate(Principal, :count) == count
    assert Repo.get!(Ankole.Principals.Invitation, created.invitation.id).used_count == 0

    assert {:ok, login} =
             Login.complete_oidc_login("lark-invite", "code",
               invitation_id: created.invitation.id
             )

    assert Repo.get!(Principal, login.principal_uid).membership == :member
    assert Repo.get!(Ankole.Principals.Invitation, created.invitation.id).used_count == 1
  end

  test "OIDC invitation keeps an existing guest's role and does not consume a new-member seat" do
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", true)
    admin = Ankole.PrincipalsFixtures.human_fixture().principal
    assert {:ok, _} = IdentityProviders.save_provider("lark-existing", "lark", config("lark"))

    assert {:ok, %{principal: guest}} =
             Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user(
               "lark-existing",
               %{"user_id" => "employee-1"},
               membership: :guest
             )

    assert {:ok, created} =
             Ankole.Principals.create_invitation(admin.uid, %{
               kind: :link,
               invited_email: nil,
               membership: :member,
               expires_at: DateTime.add(DateTime.utc_now(), 3600),
               max_uses: 1
             })

    stub_login("lark", :error)

    assert {:ok, login} =
             Login.complete_oidc_login("lark-existing", "code",
               invitation_id: created.invitation.id
             )

    assert login.principal_uid == guest.uid
    assert Repo.get!(Principal, guest.uid).membership == :guest
    assert Repo.get!(Ankole.Principals.Invitation, created.invitation.id).used_count == 0
  end

  for {adapter, module, department_key, email_key, title_key} <- [
        {"lark", Ankole.Plugins.LarkAdapter.IdentityProvider, "department_ids",
         "enterprise_email", "job_title"},
        {"dingtalk", Ankole.Plugins.DingTalkAdapter.IdentityProvider, "dept_id_list", "org_email",
         "title"},
        {"wecom", Ankole.Plugins.WeComAdapter.IdentityProvider, "department", "biz_mail",
         "position"}
      ] do
    test "#{adapter} login preserves unobserved data and explicit empty observations still clear it" do
      adapter = unquote(adapter)
      module = unquote(module)
      provider = adapter <> "-presence"
      config = config(adapter)
      assert {:ok, _} = IdentityProviders.save_provider(provider, adapter, config)

      assert {:ok, parent} =
               Directory.ensure_group(provider, %Directory.Group{
                 external_id: "2",
                 kind: "department",
                 display_name: "Engineering"
               })

      assert {:ok, child} =
               Directory.ensure_group(provider, %Directory.Group{
                 external_id: "3",
                 parent_external_id: "2",
                 kind: "department",
                 display_name: "Platform"
               })

      assert {:ok, other} =
               Directory.ensure_group("other-provider", %Directory.Group{
                 external_id: "3",
                 kind: "department",
                 display_name: "Other provider"
               })

      assert {:ok, operator} =
               AuthZ.create_principal_group(%{
                 name: "operator-team",
                 display_name: "Operator team"
               })

      user =
        subject(adapter)
        |> Map.merge(%{
          "name" => "Directory Name",
          "mobile" => "+6591234567",
          unquote(email_key) => "presence@example.com",
          unquote(title_key) => "Engineer",
          unquote(department_key) => ["3"],
          "avatar" => avatar(adapter)
        })

      assert {:ok, observed} = module.upsert_user(provider, user)
      uid = observed.principal.uid
      assert {:ok, _} = AuthZ.add_principal_to_group(uid, operator.id)

      assert {:ok, _} =
               AuthZ.sync_external_directory_group_memberships("other-provider", uid, ["3"])

      assert {:ok, _} =
               AuthZ.upsert_permission_grant(%{
                 group_id: parent.id,
                 resource_pattern: "workspace:presence",
                 action: "read"
               })

      profile = Repo.get!(HumanUser, uid)
      principal = Repo.get!(Principal, uid)
      assert AuthZ.allowed?(uid, "workspace:presence", "read", %{})

      stub_login(adapter, :error)
      assert {:ok, %{principal_uid: ^uid}} = Login.complete_oidc_login(provider, "code", [])
      Ankole.DataCase.assert_persisted_equal(Repo.get!(HumanUser, uid), profile)
      assert Repo.get!(Principal, uid).display_name == principal.display_name
      assert Repo.get!(Principal, uid).avatar_url == principal.avatar_url

      assert Repo.get!(Ankole.Principals.ExternalIdentity, observed.identity.id).metadata[
               "department_ids"
             ] == ["3"]

      for group <- [parent, child, other, operator], do: assert(member?(uid, group.id))
      assert AuthZ.allowed?(uid, "workspace:presence", "read", %{})

      if adapter == "wecom" do
        # A fresh provider has genuinely no stored secret; editing an existing
        # provider intentionally preserves omitted secrets in the Console API.
        no_secret_provider = "wecom-without-contacts"
        config = config |> Map.delete("contactsSecret") |> Map.put("sync", %{"contacts" => false})
        assert {:ok, _} = IdentityProviders.save_provider(no_secret_provider, adapter, config)

        assert {:ok, no_secret_group} =
                 Directory.ensure_group(
                   no_secret_provider,
                   %Directory.Group{
                     external_id: "3",
                     kind: "department",
                     display_name: "Known department"
                   }
                 )

        assert {:ok, %{principal: %{uid: ^uid}}} = module.upsert_user(no_secret_provider, user)

        Req.default_options(
          plug: fn conn ->
            body =
              case conn.request_path do
                "/cgi-bin/gettoken" ->
                  %{"errcode" => 0, "access_token" => "no-secret-token", "expires_in" => 7200}

                "/cgi-bin/auth/getuserinfo" ->
                  %{"errcode" => 0, "userid" => "employee-1"}

                unexpected ->
                  flunk("login without contacts secret must not hydrate: #{unexpected}")
              end

            Req.Test.json(conn, body)
          end
        )

        assert {:ok, %{principal_uid: ^uid}} =
                 Login.complete_oidc_login(no_secret_provider, "no-secret", [])

        Ankole.DataCase.assert_persisted_equal(Repo.get!(HumanUser, uid), profile)
        assert member?(uid, no_secret_group.id)
        assert member?(uid, child.id)
      end

      if adapter == "lark" do
        stub_login(adapter, :empty_body)
        assert {:ok, %{principal_uid: ^uid}} = Login.complete_oidc_login(provider, "no-body", [])
        Ankole.DataCase.assert_persisted_equal(Repo.get!(HumanUser, uid), profile)
        assert member?(uid, child.id)
      end

      assert {:ok, _} =
               module.upsert_user(provider, Map.put(subject(adapter), "name", "New Name"))

      assert Repo.get!(Principal, uid).display_name == "New Name"
      Ankole.DataCase.assert_persisted_equal(Repo.get!(HumanUser, uid), profile)

      blank =
        subject(adapter)
        |> Map.merge(%{
          "name" => "",
          "mobile" => "",
          "avatar" => nil,
          unquote(email_key) => "",
          unquote(title_key) => "",
          unquote(department_key) => []
        })

      assert {:ok, cleared} = module.upsert_user(provider, blank)
      assert cleared.principal.uid == uid
      assert cleared.principal.display_name == nil
      assert cleared.principal.avatar_url == nil
      assert Repo.get!(HumanUser, uid).email == nil
      assert Repo.get!(HumanUser, uid).mobile == nil
      assert Repo.get!(HumanUser, uid).job_title == nil
      assert cleared.identity.metadata["department_ids"] == []
      refute member?(uid, child.id)
      refute member?(uid, parent.id)
      assert member?(uid, operator.id)
      assert member?(uid, other.id)
      refute AuthZ.allowed?(uid, "workspace:presence", "read", %{})

      assert {:ok, bare} =
               module.upsert_user(
                 provider,
                 Map.new(subject(adapter), fn {key, _} -> {key, "new-subject"} end)
               )

      assert bare.principal.display_name == "new-subject"
    end
  end

  defp member?(uid, group_id),
    do: Repo.get_by(Membership, principal_uid: uid, group_id: group_id) != nil

  defp subject("lark"), do: %{"user_id" => "employee-1"}
  defp subject(_adapter), do: %{"userid" => "employee-1"}
  defp avatar("lark"), do: %{"avatar_240" => "https://example.com/avatar.png"}
  defp avatar(_adapter), do: "https://example.com/avatar.png"

  defp config("lark"),
    do: %{
      "appID" => "presence-lark",
      "appSecret" => "secret",
      "sync" => %{"contacts" => false, "websocket" => false}
    }

  defp config("dingtalk"),
    do: %{
      "clientId" => "presence-dingtalk",
      "clientSecret" => "secret",
      "sync" => %{"contacts" => false, "websocket" => false}
    }

  defp config("wecom"),
    do: %{
      "corpId" => "presence-wecom",
      "agentId" => "1000002",
      "appSecret" => "secret",
      "contactsSecret" => "contacts",
      "sync" => %{"contacts" => false}
    }

  defp stub_login(adapter, result) do
    Req.default_options(
      plug: fn conn ->
        body =
          case {adapter, conn.request_path} do
            {"wecom", "/cgi-bin/gettoken"} ->
              %{"errcode" => 0, "access_token" => "token", "expires_in" => 7200}

            {"wecom", "/cgi-bin/auth/getuserinfo"} ->
              %{"errcode" => 0, "userid" => "employee-1"}

            {"wecom", "/cgi-bin/user/get"} ->
              %{"errcode" => 60_011, "errmsg" => "no privilege"}

            {"dingtalk", "/v1.0/oauth2/accessToken"} ->
              %{"accessToken" => "app-token", "expireIn" => 7200}

            {"dingtalk", "/v1.0/oauth2/userAccessToken"} ->
              %{"accessToken" => "user-token", "expireIn" => 7200, "corpId" => "corp-1"}

            {"dingtalk", "/v1.0/contact/users/me"} ->
              %{"unionId" => "union-1"}

            {"dingtalk", "/topapi/user/getbyunionid"} ->
              %{"errcode" => 0, "result" => %{"userid" => "employee-1"}}

            {"dingtalk", "/topapi/v2/user/get"} ->
              %{"errcode" => 60_011, "errmsg" => "no privilege"}

            {"lark", "/open-apis/auth/v3/tenant_access_token/internal"} ->
              %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}

            {"lark", "/open-apis/auth/v3/app_access_token/internal"} ->
              %{"code" => 0, "app_access_token" => "app-token", "expire" => 7200}

            {"lark", "/open-apis/authen/v1/oidc/access_token"} ->
              %{"code" => 0, "data" => %{"access_token" => "user-token", "expires_in" => 7200}}

            {"lark", "/open-apis/authen/v1/user_info"} ->
              %{"code" => 0, "data" => %{"user_id" => "employee-1"}}

            {"lark", "/open-apis/contact/v3/users/employee-1"} ->
              if result == :empty_body,
                do: %{"code" => 0, "data" => %{}},
                else: %{"code" => 99_991_672, "msg" => "no privilege"}

            unexpected ->
              flunk("unexpected provider request: #{inspect(unexpected)}")
          end

        Req.Test.json(conn, body)
      end
    )
  end
end
