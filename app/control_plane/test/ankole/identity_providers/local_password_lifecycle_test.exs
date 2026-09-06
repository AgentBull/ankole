defmodule Ankole.IdentityProviders.LocalPasswordLifecycleTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals
  alias Ankole.Principals.LocalCredential

  describe "generate_initial_password/0" do
    test "returns 16 characters from the unambiguous alphabet" do
      passwords = for _round <- 1..20, do: LocalCredential.generate_initial_password()

      for password <- passwords do
        assert String.length(password) == 16
        refute password =~ ~r/[IOl01]/
      end

      assert Enum.uniq(passwords) == passwords
    end
  end

  describe "create_local_user/2" do
    test "creates the principal, profile, and credential in one call" do
      email = "new-user-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, result} =
               Principals.create_local_user(
                 %{uid: email, email: email, display_name: "New User"},
                 true
               )

      assert result.principal.uid == email
      assert result.human_user.email == email
      assert String.length(result.initial_password) == 16

      assert {:ok, login} = LocalPassword.fetch_local_login(email)
      assert login.credential.must_change_password
    end

    test "requires an email" do
      assert {:error, {:missing, :email}} = Principals.create_local_user(%{uid: "x"}, true)
    end

    test "rejects a duplicate email with a changeset error" do
      %{human_user: human_user} = human_fixture()
      email = human_user.email

      assert {:error, %Ecto.Changeset{} = changeset} =
               Principals.create_local_user(%{uid: "another-uid", email: email}, true)

      assert {"has already been taken", _meta} = changeset.errors[:email]
    end
  end

  describe "set_local_password/3" do
    test "enforces the six-character floor" do
      %{principal: principal} = human_fixture()

      assert {:error, :password_too_short} =
               LocalPassword.set_local_password(principal.uid, "12345", false)

      assert {:ok, credential} =
               LocalPassword.set_local_password(principal.uid, "123456", false)

      assert credential.password_hash =~ "$argon2id$"
    end

    test "rejects principals without a human email" do
      %{principal: agent} = agent_fixture()

      assert {:error, :not_human} =
               LocalPassword.set_local_password(agent.uid, "secret1", false)

      %{principal: no_email} = human_fixture(%{email: nil})

      assert {:error, :email_missing} =
               LocalPassword.set_local_password(no_email.uid, "secret1", false)
    end
  end

  describe "complete_forced_password_change/3" do
    test "rejects a credential version replaced by a password reset" do
      %{principal: principal, human_user: human_user} = human_fixture()

      assert {:ok, credential} =
               LocalPassword.set_local_password(principal.uid, "old-password", true)

      credential_version = LocalCredential.version(credential)
      assert {:ok, reset_password} = LocalPassword.reset_local_password(principal.uid, true)

      assert {:error, :password_change_not_required} =
               LocalPassword.complete_forced_password_change(
                 principal.uid,
                 "stale-ticket-password",
                 credential_version
               )

      assert {:ok, login} = LocalPassword.fetch_local_login(human_user.email)
      assert login.credential.must_change_password
      assert Ankole.Kernel.argon2id_verify(reset_password, login.credential.password_hash)

      refute Ankole.Kernel.argon2id_verify(
               "stale-ticket-password",
               login.credential.password_hash
             )
    end
  end

  describe "reset_local_password/2 and reset_local_password_by_email/1" do
    test "replaces the credential with a generated must-change password" do
      %{principal: principal, human_user: human_user} = human_fixture()

      {:ok, _credential} =
        LocalPassword.set_local_password(principal.uid, "old-password", false)

      assert {:ok, %{principal_uid: uid, initial_password: initial_password}} =
               LocalPassword.reset_local_password_by_email(String.upcase(human_user.email))

      assert uid == principal.uid
      assert String.length(initial_password) == 16

      assert {:ok, login} = LocalPassword.fetch_local_login(human_user.email)
      assert login.credential.must_change_password
      assert Ankole.Kernel.argon2id_verify(initial_password, login.credential.password_hash)
      refute Ankole.Kernel.argon2id_verify("old-password", login.credential.password_hash)
    end

    test "reports a miss for an unknown email" do
      assert {:error, :not_found} =
               LocalPassword.reset_local_password_by_email("nobody@example.com")
    end
  end

  describe "account read model" do
    test "carries email, external identity, and credential facts" do
      %{principal: principal, human_user: human_user} = human_fixture()

      assert {:ok, account} = Principals.get_principal_account(principal.uid)
      assert account.email == human_user.email
      refute account.has_external_identity
      assert account.local_credential_status == nil

      {:ok, _credential} = LocalPassword.set_local_password(principal.uid, "secret1", true)
      assert {:ok, account} = Principals.get_principal_account(principal.uid)
      assert account.local_credential_status == :must_change

      {:ok, _credential} = LocalPassword.set_local_password(principal.uid, "secret1", false)
      assert {:ok, account} = Principals.get_principal_account(principal.uid)
      assert account.local_credential_status == :active

      {:ok, _identity} =
        Principals.create_external_identity(%{
          principal_uid: principal.uid,
          provider: "lark",
          external_id: "ou-#{System.unique_integer([:positive])}"
        })

      assert {:ok, %{has_external_identity: true}} =
               Principals.get_principal_account(principal.uid)

      accounts = Principals.list_principal_accounts()
      listed = Enum.find(accounts, &(&1.principal.uid == principal.uid))
      assert listed.local_credential_status == :active
      assert listed.has_external_identity
    end
  end
end
