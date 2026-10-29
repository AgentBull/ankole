defmodule Ankole.OIDC.LoginPolicyTest do
  use Ankole.DataCase, async: false
  alias Ankole.OIDC.LoginPolicy

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "lark-main",
        "lark",
        %{"appID" => "cli_policy", "appSecret" => "secret"},
        true
      )

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "other",
        "lark",
        %{"appID" => "test", "appSecret" => "test"},
        true
      )

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Selection policy",
        type: "public",
        enabled: true,
        redirect_uris: ["https://client.example.test/callback"],
        scopes: ["openid"],
        allowed_identity_provider_ids: ["lark-main"]
      })

    auth = %{
      "authentication_id" => Ecto.UUID.generate(),
      "authentication_revision" => 1,
      "provider_id" => "lark-main",
      "auth_time" => System.system_time(:second) - 60
    }

    transaction = %{
      status: :pending,
      request: %{"client_id" => client.id, "prompt" => ["select_account"]},
      authentication_id: nil,
      authentication_revision: nil
    }

    {:ok, auth: auth, transaction: transaction}
  end

  test "selection removes only the selection requirement", %{transaction: transaction, auth: auth} do
    for {params, action} <- [
          {%{}, :reuse},
          {%{"prompt" => ["login", "select_account"]}, :reauthenticate},
          {%{"max_age" => 0}, :reauthenticate},
          {%{"max_age" => 1}, :reauthenticate},
          {%{"max_age" => 3600}, :reuse}
        ] do
      transaction = %{transaction | request: Map.merge(transaction.request, params)}
      assert LoginPolicy.selection_required?(transaction.request)
      assert {:ok, selected, ^action} = LoginPolicy.select_authentication(transaction, auth)
      assert Map.delete(selected, "selection_confirmed") == transaction.request
      refute LoginPolicy.selection_required?(selected)
    end
  end

  test "selection cannot supply a missing authentication time", %{
    transaction: transaction,
    auth: auth
  } do
    request =
      Map.put(
        transaction.request,
        "auth_time_essential?",
        true
      )

    assert {:ok, _, :reauthenticate} =
             LoginPolicy.select_authentication(
               %{transaction | request: request},
               Map.delete(auth, "auth_time")
             )
  end

  test "a completed authentication satisfies login only for that exact proof", %{
    transaction: transaction,
    auth: auth
  } do
    transaction = %{
      transaction
      | status: :authenticated,
        request: Map.put(transaction.request, "prompt", ["login", "select_account"]),
        authentication_id: auth["authentication_id"],
        authentication_revision: auth["authentication_revision"]
    }

    refute LoginPolicy.authorization_ready?(transaction)
    assert {:ok, selected, :reuse} = LoginPolicy.select_authentication(transaction, auth)
    assert LoginPolicy.authorization_ready?(%{transaction | request: selected})

    assert {:ok, _, :reauthenticate} =
             LoginPolicy.select_authentication(
               transaction,
               Map.put(auth, "authentication_revision", 2)
             )

    assert {:ok, _, :reauthenticate} =
             LoginPolicy.select_authentication(
               transaction,
               Map.put(auth, "authentication_id", Ecto.UUID.generate())
             )

    refute LoginPolicy.authorization_ready?(%{transaction | status: :pending, request: selected})
  end

  test "selection retains the Client source restriction", %{transaction: transaction, auth: auth} do
    assert {:error, :identity_provider_not_allowed} =
             LoginPolicy.select_authentication(
               transaction,
               Map.put(auth, "provider_id", "other")
             )
  end

  test "combined prompts force upstream login while account selection stays in the authorization request" do
    selected_at = DateTime.utc_now()

    request = %{"prompt" => ["login", "select_account"], "max_age" => 3600}
    opts = LoginPolicy.upstream_options("upstream-nonce", request, selected_at)

    assert opts[:prompt] == "login"
    assert opts[:max_age] == 0
    assert opts[:nonce] == "upstream-nonce"
    assert opts[:auth_time_required]
    assert opts[:auth_time_not_before] == DateTime.to_unix(selected_at)
    assert LoginPolicy.selection_required?(request)
  end
end
