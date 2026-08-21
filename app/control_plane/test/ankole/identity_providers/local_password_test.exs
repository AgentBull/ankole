defmodule Ankole.IdentityProviders.LocalPasswordTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.IdentityProviders.LocalPassword.RetryGuard
  alias Ankole.IdentityProviders.Login
  alias Ankole.Principals

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
    RetryGuard.reset_for_test()
    :ok
  end

  defp save_local_provider(config \\ %{}) do
    {:ok, provider} = IdentityProviders.save_provider("local-main", "local", config, true)
    provider
  end

  defp local_user(password, must_change \\ false) do
    %{principal: principal, human_user: human_user} = human_fixture()
    {:ok, _credential} = Principals.set_local_password(principal.uid, password, must_change)
    %{principal: principal, email: human_user.email}
  end

  describe "adapter catalog" do
    test "the built-in local adapter passes the shared declaration validation" do
      assert :ok =
               IdentityProviders.validate_adapter_declaration(LocalPassword.adapter_declaration())
    end

    test "the local adapter appears in the setup and console catalogs" do
      assert [%{adapter_id: "local", plugin_id: "control-plane"} | _rest] =
               IdentityProviders.list_active_adapters()

      assert [%{adapter_id: "local", default_provider_id: "local-main"} | _rest] =
               IdentityProviders.list_adapters()

      assert {:ok, _adapter} = IdentityProviders.fetch_adapter("local")
    end

    test "saving a local provider skips directory sync and marks it active" do
      provider = save_local_provider()

      assert provider["adapter_id"] == "local"
      assert provider["config_key"] == "principals.identity_providers.local.local-main"
      assert LocalPassword.enabled?()
      assert {:ok, %{"provider_id" => "local-main"}} = LocalPassword.fetch_enabled_provider()
    end

    test "the local provider lists as a password login provider" do
      save_local_provider()

      assert {:ok, [provider]} = Login.list_login_providers()
      assert provider["provider_id"] == "local-main"
      assert provider["kind"] == "password"
    end
  end

  describe "authenticate/3" do
    test "fails when no local provider is enabled" do
      assert {:error, :no_local_provider} = LocalPassword.authenticate("a@example.com", "secret1")
    end

    test "rejects an unknown email and a wrong password the same way" do
      save_local_provider()
      %{email: email} = local_user("correct-horse")

      assert {:error, :invalid_credentials} =
               LocalPassword.authenticate("nobody@example.com", "whatever")

      assert {:error, :invalid_credentials} = LocalPassword.authenticate(email, "wrong-password")
    end

    test "verifies a correct password and reports the must-change flag" do
      save_local_provider()
      %{principal: principal, email: email} = local_user("correct-horse")

      assert {:ok, login} = LocalPassword.authenticate(String.upcase(email), "correct-horse")
      assert login.principal_uid == principal.uid
      assert login.provider_id == "local-main"
      assert login.email == email
      refute login.must_change_password

      %{email: must_change_email} = local_user("initial-pass", true)

      assert {:ok, %{must_change_password: true}} =
               LocalPassword.authenticate(must_change_email, "initial-pass")
    end

    test "refuses a disabled account after the password verifies" do
      save_local_provider()
      %{principal: principal, email: email} = local_user("correct-horse")
      {:ok, _principal} = Principals.disable_principal(principal.uid)

      assert {:error, :account_disabled} = LocalPassword.authenticate(email, "correct-horse")
    end

    test "locks an account after five failures inside the window" do
      save_local_provider()
      %{email: email} = local_user("correct-horse")

      for _attempt <- 1..5 do
        assert {:error, :invalid_credentials} = LocalPassword.authenticate(email, "wrong")
      end

      assert {:error, {:retry_locked, retry_after}} =
               LocalPassword.authenticate(email, "correct-horse")

      assert retry_after in 1..(30 * 60)

      # The lock keys on the account, not on the whole installation.
      %{email: other_email} = local_user("other-pass")
      assert {:ok, _login} = LocalPassword.authenticate(other_email, "other-pass")
    end

    test "a password reset unlocks a locked account at once" do
      save_local_provider()
      %{principal: principal, email: email} = local_user("correct-horse")

      for _attempt <- 1..5 do
        assert {:error, :invalid_credentials} = LocalPassword.authenticate(email, "wrong")
      end

      assert {:error, {:retry_locked, _seconds}} =
               LocalPassword.authenticate(email, "correct-horse")

      # The reset writes a new credential row; failures against the old
      # password stop counting, including when the reset ran in another OS
      # process (a rescue command) that cannot reach this RetryGuard.
      assert {:ok, initial_password} = Principals.reset_local_password(principal.uid, true)

      assert {:ok, %{must_change_password: true}} =
               LocalPassword.authenticate(email, initial_password)
    end

    test "a successful sign-in clears the failure history" do
      save_local_provider()
      %{email: email} = local_user("correct-horse")

      for _attempt <- 1..4 do
        assert {:error, :invalid_credentials} = LocalPassword.authenticate(email, "wrong")
      end

      assert {:ok, _login} = LocalPassword.authenticate(email, "correct-horse")

      for _attempt <- 1..4 do
        assert {:error, :invalid_credentials} = LocalPassword.authenticate(email, "wrong")
      end

      assert {:ok, _login} = LocalPassword.authenticate(email, "correct-horse")
    end

    test "an operator can turn retry protection off" do
      save_local_provider(%{"retry_protection" => %{"enabled" => false}})
      %{email: email} = local_user("correct-horse")

      for _attempt <- 1..6 do
        assert {:error, :invalid_credentials} = LocalPassword.authenticate(email, "wrong")
      end

      assert {:ok, _login} = LocalPassword.authenticate(email, "correct-horse")
    end
  end
end
