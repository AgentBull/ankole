defmodule Ankole.AIAgent.CodexAccountsTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.AIAgent.CodexAccounts.Account
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  test "create and update derive account identity and auth hash from auth.json" do
    initial_auth = auth_json("account-123", "initial-token")

    assert {:ok, %Account{} = account} =
             CodexAccounts.create_account(%{
               "name" => "Team subscription",
               "auth_json" => initial_auth
             })

    assert account.account_id == "account-123"
    assert account.auth_hash == NativeKernel.generic_hash(initial_auth)
    refute account.encrypted_auth_json == initial_auth

    assert {:ok, resolved} = CodexAccounts.resolve_auth(account.account_id)
    assert resolved.auth_json == initial_auth
    assert resolved.auth_hash == account.auth_hash

    refreshed_auth = auth_json(account.account_id, "refreshed-token")
    assert {:ok, refreshed} = CodexAccounts.update_auth(account.account_id, refreshed_auth)
    assert refreshed.auth_hash == NativeKernel.generic_hash(refreshed_auth)
    refute refreshed.auth_hash == account.auth_hash

    assert {:ok, renamed} =
             CodexAccounts.update_account(account.account_id, %{"name" => "Primary subscription"})

    assert renamed.name == "Primary subscription"
    assert renamed.auth_hash == refreshed.auth_hash
  end

  test "operator names are unique case-insensitively and account identity cannot change" do
    assert {:ok, _account} =
             CodexAccounts.create_account(%{
               "name" => "Operations",
               "auth_json" => auth_json("account-ops", "first-token")
             })

    assert {:error, %Ecto.Changeset{} = changeset} =
             CodexAccounts.create_account(%{
               "name" => "operations",
               "auth_json" => auth_json("account-other", "second-token")
             })

    assert "has already been taken" in errors_on(changeset).name

    assert {:error, :codex_account_id_mismatch} =
             CodexAccounts.update_auth(
               "account-ops",
               auth_json("different-account", "third-token")
             )

    assert Repo.aggregate(Account, :count) == 1
  end

  test "coding subscription profiles select an account and normalize Codex settings" do
    %{principal: agent} = agent_fixture()

    assert {:ok, account} =
             CodexAccounts.create_account(%{
               "name" => "Coding account",
               "auth_json" => auth_json("account-coding", "coding-token")
             })

    assert {:ok,
            %{
              profile: %{
                "codex_account_id" => account_id,
                "model" => "gpt-5.6-sol",
                "model_reasoning_effort" => "high",
                "fast_mode" => false
              }
            }} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               "codex_account_id" => account.account_id
             })

    assert account_id == account.account_id

    assert {:ok,
            %{
              profile: %{
                "model" => "gpt-5.6-terra",
                "model_reasoning_effort" => "ultra",
                "fast_mode" => true
              }
            }} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               "codex_account_id" => account.account_id,
               "model" => "gpt-5.6-terra",
               "model_reasoning_effort" => "ultra",
               "fast_mode" => true
             })

    assert {:error, :invalid_codex_account_profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               "codex_account_id" => account.account_id,
               "provider_id" => "must-not-coexist"
             })

    assert {:error, :invalid_codex_model_reasoning_effort} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               "codex_account_id" => account.account_id,
               "model_reasoning_effort" => "extreme"
             })
  end

  defp auth_json(account_id, access_token) do
    Ankole.JSON.encode!(%{
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "access_token" => access_token,
        "account_id" => account_id,
        "id_token" => "id-token",
        "refresh_token" => "refresh-token"
      }
    })
  end
end
