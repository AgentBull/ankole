defmodule Ankole.Principals.OffboardingCredentialsTest do
  use Ankole.DataCase, async: false
  alias Ankole.{Principals, Repo}
  alias Ankole.IdentityProviders.Directory
  alias Ankole.Principals.HumanAccess

  test "suspend, offboard, suspend with the same reason preserves the departure and stops directory contact restoration" do
    attrs = %{
      provider: "lark-main",
      external_id: "old-user",
      email: "recycled@acme.com",
      mobile: "+14155550123",
      contact_emails: [%{email: "personal@example.com", kind: "member"}]
    }

    assert {:ok, %{principal: principal}} = Directory.upsert_user("lark-main", attrs)

    proof = %{
      provider_id: "email_otp",
      subject_id: attrs.email,
      verified_email: attrs.email,
      challenge_started_at: DateTime.utc_now()
    }

    assert {:ok, _} =
             Repo.transact(fn -> Principals.bind_site_credential_in_tx(principal.uid, proof) end)

    assert {:ok, suspended} =
             HumanAccess.disable(principal.uid, "same reason", nil, "suspend-1", :suspended)

    refute HumanAccess.offboarded_in_current_cycle?(suspended)
    assert Principals.site_credential_bound?(principal.uid, "email_otp", attrs.email)

    assert [%{external_id: "personal@example.com"}] =
             Principals.list_external_identities!(
               query: [filter: [provider: "email", external_id: "personal@example.com"]]
             )

    assert {:ok, departed} =
             HumanAccess.disable(principal.uid, "same reason", nil, "offboard", :offboarded)

    assert HumanAccess.offboarded_in_current_cycle?(departed)
    refute Principals.site_credential_bound?(principal.uid, "email_otp", attrs.email)

    assert {:ok, _} =
             HumanAccess.disable(principal.uid, "same reason", nil, "suspend-2", :suspended)

    assert [:offboarded, :suspended] ==
             HumanAccess.restrictions(principal.uid) |> Enum.map(& &1.disposition) |> Enum.sort()

    assert {:ok, observed} = Principals.upsert_platform_subject_human(attrs)
    assert observed.principal.uid == principal.uid
    assert is_nil(observed.human_user.email)
    assert is_nil(observed.human_user.mobile)
    assert {:ok, observed} = Directory.upsert_user("lark-main", attrs)
    assert HumanAccess.offboarded_in_current_cycle?(observed.principal)

    assert [] ==
             Principals.list_external_identities!(
               query: [filter: [provider: "email", principal_uid: principal.uid]]
             )

    assert {:ok, %{principal: newcomer, human_user: human}} =
             Directory.upsert_user("lark-main", %{attrs | external_id: "new-user"})

    refute newcomer.uid == principal.uid
    assert human.email == attrs.email
    assert human.mobile == attrs.mobile

    assert {:ok, _} =
             Repo.transact(fn -> Principals.bind_site_credential_in_tx(newcomer.uid, proof) end)

    refute Principals.site_credential_claim_current?(proof)

    assert Enum.any?(
             HumanAccess.history(principal.uid),
             &("email:recycled@acme.com" in &1.released_identifiers)
           )
  end

  test "enterprise directory joins the active personal-credential member and preserves its UID and administrator role" do
    assert {:ok, %{principal: owner}} =
             Principals.create_human(%{display_name: "Owner", email: "owner@example.com"})

    proof = %{
      provider_id: "email_otp",
      subject_id: "owner@example.com",
      verified_email: "owner@example.com"
    }

    {:ok, _} =
      Repo.transact_top_level(fn ->
        {:ok, _} = Principals.bind_site_credential_in_tx(owner.uid, proof)
        {:ok, group} = Ankole.AuthZ.Root.ensure_pod_admin_group()
        {:ok, _} = Ankole.AuthZ.Grants.upsert_pod_admin_grants(group)
        Ankole.AuthZ.add_pod_admin_in_tx(owner.uid)
      end)

    assert {:ok, observed} =
             Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user("lark-main", %{
               "user_id" => "owner-stable-id",
               "enterprise_email" => "work@example.com",
               "email" => "owner@example.com"
             })

    assert observed.principal.uid == owner.uid
    assert Ankole.AuthZ.pod_admin?(owner.uid)
    assert Principals.site_credential_bound?(owner.uid, "email_otp", "owner@example.com")
    assert {:ok, uid} = Principals.resolve_platform_subject_uid("lark-main", "owner-stable-id")
    assert uid == owner.uid
    assert length(Principals.list_principals!(query: [filter: [type: :human]])) == 1
  end

  test "different subjects of the same enterprise provider do not merge on contact email" do
    attrs = %{provider: "lark-main", external_id: "person-1", email: "shared@example.com"}
    assert {:ok, first} = Principals.upsert_platform_subject_human(attrs)

    assert {:ok, second} =
             Principals.upsert_platform_subject_human(%{attrs | external_id: "person-2"})

    refute first.principal.uid == second.principal.uid
    assert is_nil(second.human_user.email)
  end

  test "offboarding preserves an immutable enterprise subject that contains an at sign" do
    assert {:ok, observed} =
             Principals.upsert_platform_subject_human(%{
               provider: "enterprise-oidc",
               external_id: "stable-sub@example.org",
               email: "contact@example.org",
               contact_emails: [%{email: "contact@example.org", kind: "member"}]
             })

    uid = observed.principal.uid
    assert {:ok, _} = HumanAccess.disable(uid, "departure", nil, "oidc-offboard", :offboarded)

    assert [%{provider: "enterprise-oidc", external_id: "stable-sub@example.org"}] =
             Principals.list_external_identities!(query: [filter: [principal_uid: uid]])
  end
end
