defmodule Ankole.IdentityProviders.OIDCTest do
  use ExUnit.Case, async: false

  alias Ankole.IdentityProviders.OIDC
  alias Ankole.OIDCClientFixture

  @issuer "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0"
  @verification %{issuer: @issuer, client_id: "client-1", subject_claim: "sub"}

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
  end

  test "signed auth_time survives discovery, JWKS, nonce and maximum-age validation" do
    now = System.system_time(:second)
    {token, jwks} = OIDCClientFixture.token(@issuer, "client-1", %{"auth_time" => now})
    Req.Test.stub(__MODULE__, &OIDCClientFixture.discovery(&1, @issuer, jwks))

    assert {:ok, ^now} =
             OIDC.verify_login(@verification, login(token),
               nonce: "nonce-1",
               auth_time_required: true,
               max_age: 60,
               auth_time_not_before: now
             )
  end

  test "a fresh response with missing or stale proof cannot authenticate" do
    now = System.system_time(:second)

    for claims <- [%{}, %{"auth_time" => now - 600}] do
      {token, jwks} = OIDCClientFixture.token(@issuer, "client-1", claims)
      Req.Test.stub(__MODULE__, &OIDCClientFixture.discovery(&1, @issuer, jwks))

      assert {:error, {:invalid_id_token, reason}} =
               OIDC.verify_login(@verification, login(token),
                 nonce: "nonce-1",
                 auth_time_required: true,
                 auth_time_not_before: now,
                 max_age: 0
               )

      assert reason in [:authentication_time_unavailable, :authentication_too_old]
    end
  end

  test "ordinary login preserves an unknown authentication time" do
    {token, jwks} = OIDCClientFixture.token(@issuer, "client-1")
    Req.Test.stub(__MODULE__, &OIDCClientFixture.discovery(&1, @issuer, jwks))

    assert {:ok, nil} = OIDC.verify_login(@verification, login(token), nonce: "nonce-1")
  end

  test "wrong signature, issuer, audience, nonce, expired token and old authentication fail closed" do
    now = System.system_time(:second)

    for {claims, reason} <- [
          {%{"iss" => "https://attacker.example.com"}, :invalid_issuer},
          {%{"aud" => "another-client"}, :invalid_audience},
          {%{"nonce" => "another-nonce"}, :nonce_mismatch},
          {%{"exp" => now - 1}, :expired},
          {%{"auth_time" => now - 600}, :max_age_exceeded},
          {%{"auth_time" => now + 600}, :invalid_auth_time}
        ] do
      {token, jwks} =
        OIDCClientFixture.token(@issuer, "client-1", Map.merge(%{"auth_time" => now}, claims))

      Req.Test.stub(__MODULE__, &OIDCClientFixture.discovery(&1, @issuer, jwks))

      assert {:error, {:invalid_id_token, ^reason}} =
               OIDC.verify_login(@verification, login(token), nonce: "nonce-1", max_age: 60)
    end

    {token, _jwks} = OIDCClientFixture.token(@issuer, "client-1")
    {_other, wrong_jwks} = OIDCClientFixture.token(@issuer, "client-1")
    Req.Test.stub(__MODULE__, &OIDCClientFixture.discovery(&1, @issuer, wrong_jwks))

    assert {:error, {:invalid_id_token, :invalid_signature}} =
             OIDC.verify_login(@verification, login(token), nonce: "nonce-1")

    assert {:error, :oidc_nonce_required} = OIDC.verify_login(@verification, login(token), [])

    assert {:error, {:invalid_id_token, :invalid_token}} =
             OIDC.verify_login(@verification, login(nil), nonce: "nonce-1")
  end

  test "UserInfo must belong to the signed subject" do
    {token, jwks} = OIDCClientFixture.token(@issuer, "client-1", %{"sub" => "one"})
    Req.Test.stub(__MODULE__, &OIDCClientFixture.discovery(&1, @issuer, jwks))

    assert {:ok, nil} =
             OIDC.verify_login(@verification, login(token, %{"sub" => "one"}), nonce: "nonce-1")

    for claims <- [%{"sub" => "two"}, %{}] do
      assert {:error, :oidc_subject_mismatch} =
               OIDC.verify_login(@verification, login(token, claims), nonce: "nonce-1")
    end

    assert {:error, :oidc_subject_mismatch} =
             OIDC.verify_login(
               %{@verification | subject_claim: "oid"},
               login(token, %{"oid" => nil}),
               nonce: "nonce-1"
             )
  end

  test "a login without an ID token has no authentication time" do
    assert {:ok, nil} = OIDC.verify_login(:none, %{user: %{}}, [])

    assert {:error, :authentication_time_unavailable} =
             OIDC.verify_login(:none, %{user: %{}}, auth_time_required: true)

    assert {:error, :invalid_oidc_login} =
             OIDC.verify_login(@verification, %{user: %{}}, nonce: "nonce-1")
  end

  test "Slack verifies the ID Token before accepting UserInfo and preserves its authentication time" do
    now = System.system_time(:second)

    {id_token, jwks} =
      OIDCClientFixture.token("https://slack.com", "slack-client", %{
        "sub" => "U123",
        "auth_time" => now
      })

    config = %{"clientID" => "slack-client", "clientSecret" => "secret"}
    adapter = Ankole.Plugins.SlackAdapter.IdentityProvider
    opts = [redirect_uri: "https://ankole.example.test/callback", nonce: "nonce-1"]

    for subject <- ["U123", "other"] do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/openid.connect.token" ->
            Req.Test.json(
              conn,
              %{"ok" => true, "access_token" => "access", "id_token" => id_token}
            )

          "/api/openid.connect.userInfo" ->
            Req.Test.json(
              conn,
              %{
                "ok" => true,
                "sub" => subject,
                "https://slack.com/user_id" => "ignored-alias",
                "email" => "human@example.com"
              }
            )

          _discovery ->
            OIDCClientFixture.discovery(conn, "https://slack.com", jwks)
        end
      end)

      assert {:ok, login} = adapter.exchange_code(config, "code", opts)
      result = OIDC.verify_login(adapter.id_token_verification(config), login, opts)

      if subject == "U123" do
        assert {:ok, ^now} = result
        assert %{"user_id" => "U123"} = login.user
      else
        assert {:error, :oidc_subject_mismatch} = result
      end
    end
  end

  defp login(id_token, claims \\ %{"sub" => "subject-1"}),
    do: %{token: %{id_token: id_token, access_token: "access"}, claims: claims, user: %{}}
end
