defmodule Ankole.OIDC.RefreshStoreTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.OIDC.{RefreshStore, RefreshToken, RefreshTokenFamily, Sessions}

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    human = human_fixture()

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Refresh rotation",
        type: "public",
        enabled: true,
        redirect_uris: ["https://refresh.example/callback"],
        scopes: ["openid", "offline_access"],
        allowed_group_ids: [],
        allowed_models: %{}
      })

    {:ok, session} =
      Ankole.OIDCFixtures.session(human.principal.uid, client.id, "openid offline_access")

    context = %{
      subject: human.principal.uid,
      client_id: client.id,
      scope: ["openid", "offline_access"],
      auth_time: session.auth_time,
      claims: %{"session_id" => session.id}
    }

    # The code exchange issues the first token of a family in its transaction.
    {:ok, issued} =
      Repo.transact(fn ->
        Attesto.RefreshToken.issue(RefreshStore, context, ttl: 2_592_000, family_ttl: 2_592_000)
      end)

    {:ok, client: client, session: session, issued: issued}
  end

  test "an online authorization of the same login keeps the Session of live refresh tokens",
       ctx do
    authentication =
      Ankole.BrowserSessions.identity(
        %{
          "id" => ctx.session.authentication_id,
          "revision" => ctx.session.authentication_revision
        },
        Repo.tenant_id!()
      )

    assert {:ok, session} = Sessions.ensure(ctx.client.id, authentication, "openid")
    assert session.id == ctx.session.id
    assert session.expires_at == ctx.session.expires_at

    assert {:ok, %{refresh_token: rotated}} =
             Ankole.OIDC.Grants.exchange(ctx.client, %{
               "grant_type" => "refresh_token",
               "refresh_token" => ctx.issued.token
             })

    assert rotated != ctx.issued.token
  end

  test "rotation persists encrypted successor and retries return the same live child", ctx do
    now = System.system_time(:second)
    opts = [client_id: ctx.client.id, ttl: 2_592_000, now: now]
    assert {:ok, rotated} = Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token, opts)
    assert {:ok, retried} = Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token, opts)
    assert retried == rotated
    parent = Repo.get!(RefreshToken, Attesto.Secret.hash(ctx.issued.token))
    refute Map.has_key?(parent.context, "subject")
    refute Map.has_key?(parent.context, "client_id")
    refute Map.has_key?(parent.context, "scope")
    refute Map.has_key?(parent.context["claims"], "session_id")
    assert parent.consumed_at
    assert is_binary(parent.successor_ciphertext)
    refute String.contains?(parent.successor_ciphertext, rotated.token)
    assert {:ok, stored} = RefreshStore.get(parent.digest)
    assert stored.data.subject == parent.principal_uid
    assert stored.data.client_id == parent.client_id
    assert stored.data.scope == ["openid", "offline_access"]
    assert stored.data.claims["session_id"] == parent.session_id
    assert stored.successor.token == rotated.token
    assert stored.successor.context == stored.data
    assert rotated.expires_at <= ctx.issued.expires_at
  end

  test "a replay after the retry deadline revokes the whole family and session", ctx do
    now = System.system_time(:second)
    opts = [client_id: ctx.client.id, ttl: 2_592_000, now: now]
    assert {:ok, rotated} = Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token, opts)

    assert {:error, :reuse_detected} =
             Attesto.RefreshToken.rotate(
               RefreshStore,
               ctx.issued.token,
               Keyword.put(opts, :now, now + 11)
             )

    assert :error = RefreshStore.get(Attesto.Secret.hash(rotated.token))
    assert Repo.get!(RefreshTokenFamily, ctx.issued.family_id).revoked_at
    assert {:ok, session} = Sessions.get(ctx.session.id)
    assert session.revoked_at
  end

  test "a wrong Client and a widened scope do not consume an unused token", ctx do
    opts = [client_id: Ankole.Ecto.UUIDv7.autogenerate(), ttl: 2_592_000]

    assert {:error, :client_mismatch} =
             Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token, opts)

    assert {:error, :invalid_scope} =
             Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token,
               client_id: ctx.client.id,
               scope: ["openid", "profile"],
               ttl: 2_592_000
             )

    assert {:ok, %{consumed: false}} = RefreshStore.get(Attesto.Secret.hash(ctx.issued.token))

    assert {:ok, _} =
             Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token,
               client_id: ctx.client.id,
               ttl: 2_592_000
             )
  end

  test "reading an expired retry hides the successor without changing stored credentials", ctx do
    now = System.system_time(:second)

    assert {:ok, _} =
             Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token,
               client_id: ctx.client.id,
               ttl: 2_592_000,
               now: now - 20
             )

    row = Repo.get!(RefreshToken, Attesto.Secret.hash(ctx.issued.token))
    assert is_binary(row.successor_ciphertext)
    assert {:ok, %{successor: %{recoverable: false}}} = RefreshStore.get(row.digest)
    Ankole.DataCase.assert_persisted_equal(Repo.get!(RefreshToken, row.digest), row)
  end

  test "cleanup redacts retry credentials and retains the replay tombstone", ctx do
    now = System.system_time(:second)

    assert {:ok, _} =
             Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token,
               client_id: ctx.client.id,
               ttl: 2_592_000,
               now: now
             )

    assert :ok = RefreshStore.redact_expired_successors(DateTime.from_unix!(now + 11))
    row = Repo.get!(RefreshToken, Attesto.Secret.hash(ctx.issued.token))
    assert is_nil(row.successor_ciphertext)
    assert row.consumed_at
    assert {:ok, %{successor: %{recoverable: false}}} = RefreshStore.get(row.digest)

    assert {:error, :reuse_detected} =
             Attesto.RefreshToken.rotate(RefreshStore, ctx.issued.token,
               client_id: ctx.client.id,
               ttl: 2_592_000,
               now: now + 11
             )
  end
end
