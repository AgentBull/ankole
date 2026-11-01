defmodule Ankole.OIDC.CredentialResourceActionsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.OIDC.{AuthorizationCode, CodeStore, RefreshStore, RefreshToken, RefreshTokenFamily}

  setup do
    %{principal: human} = human_fixture()

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Credential actions",
        type: "public",
        enabled: true,
        allowed_models: %{},
        allowed_group_ids: [],
        redirect_uris: ["https://rp.example/callback"],
        scopes: ["openid", "offline_access"]
      })

    {:ok, session} = Ankole.OIDCFixtures.session(human.uid, client.id, "openid offline_access")
    %{session: session}
  end

  test "an unconsumed authorization Code follows its Principal rename", ctx do
    code = code(ctx.session)

    assert {:ok, %{principal: renamed}} =
             Ankole.Principals.rename(ctx.session.principal_uid, "renamed-code-owner")

    assert {:ok, grant} = CodeStore.take(code.digest)
    assert grant.data.subject == renamed.uid
    assert grant.data.claims["session_id"] == ctx.session.id
  end

  test "Code consumption commits once and finalization cannot replace its replay facts", ctx do
    code = code(ctx.session)
    assert {:ok, grant} = CodeStore.take(code.digest)
    assert grant.data.claims["session_id"] == ctx.session.id
    consumed = Repo.get!(AuthorizationCode, code.digest)
    assert %DateTime{} = consumed.consumed_at
    refute consumed.finalized
    assert :error = CodeStore.take(code.digest)
    issued = refresh(ctx.session)
    assert :ok = CodeStore.mark_consumed(code.digest, %{family_id: issued.family_id})
    finalized = Repo.get!(AuthorizationCode, code.digest)
    assert {:error, :consumed, meta} = CodeStore.take(code.digest)
    assert meta.family_id == issued.family_id
    assert meta.replay_retain_until == DateTime.to_unix(finalized.replay_retain_until)

    assert {:error, _} =
             Repo.transact(fn ->
               Ankole.Ash.update(finalized, :finalize_in_tx, %{
                 family_id: "replacement",
                 replay_retain_until: DateTime.add(DateTime.utc_now(), 7200)
               })
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(AuthorizationCode, code.digest), finalized)
  end

  test "Code actions cannot create a consumed credential or replace its authorization", ctx do
    count = Repo.aggregate(AuthorizationCode, :count)

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.create(
                 AuthorizationCode,
                 :issue_in_tx,
                 Map.put(code_attrs(ctx.session), :finalized, true)
               )
             end)

    assert Enum.map(rejected.errors, & &1.input) == [:finalized]
    assert Repo.aggregate(AuthorizationCode, :count) == count
    code = code(ctx.session)

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(code, :consume_in_tx, %{
                 at: DateTime.utc_now(),
                 client_id: Ankole.Ecto.UUIDv7.autogenerate(),
                 consumed_at: nil
               })
             end)

    assert MapSet.new(Enum.map(rejected.errors, & &1.input)) ==
             MapSet.new([:client_id, :consumed_at])

    Ankole.DataCase.assert_persisted_equal(Repo.get!(AuthorizationCode, code.digest), code)
  end

  test "family identity and absolute deadline remain fixed and revocation retains its first marker",
       ctx do
    issued = refresh(ctx.session)
    family = Repo.get!(RefreshTokenFamily, issued.family_id)
    first = DateTime.utc_now()

    assert {:ok, revoked} =
             Repo.transact(fn ->
               Ankole.Ash.update(family, :revoke_in_tx, %{at: first})
             end)

    assert {:ok, repeated} =
             Repo.transact(fn ->
               Ankole.Ash.update(revoked, :revoke_in_tx, %{at: DateTime.add(first, 60)})
             end)

    assert repeated.revoked_at == first
    assert repeated.family_expires_at == family.family_expires_at

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(repeated, :revoke_in_tx, %{
                 session_id: Ankole.Ecto.UUIDv7.autogenerate(),
                 family_expires_at: DateTime.add(family.family_expires_at, 3600)
               })
             end)

    assert MapSet.new(Enum.map(rejected.errors, & &1.input)) ==
             MapSet.new([:session_id, :family_expires_at])

    Ankole.DataCase.assert_persisted_equal(Repo.get!(RefreshTokenFamily, family.id), repeated)
  end

  test "a consumed Refresh cannot overwrite its successor or authorization", ctx do
    issued = refresh(ctx.session)

    assert {:ok, rotated} =
             Attesto.RefreshToken.rotate(RefreshStore, issued.token,
               client_id: ctx.session.client_id
             )

    parent = Repo.get!(RefreshToken, Attesto.Secret.hash(issued.token))

    assert {:error, _} =
             Repo.transact(fn ->
               Ankole.Ash.update(parent, :consume_in_tx, %{
                 at: DateTime.utc_now(),
                 successor_ciphertext: "replacement",
                 successor_retry_until: DateTime.add(DateTime.utc_now(), 10)
               })
             end)

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(parent, :redact_successor_in_tx, %{
                 at: DateTime.utc_now(),
                 scope: "openid",
                 generation: 99,
                 consumed_at: nil
               })
             end)

    assert MapSet.new(Enum.map(rejected.errors, & &1.input)) ==
             MapSet.new([:scope, :generation, :consumed_at])

    Ankole.DataCase.assert_persisted_equal(Repo.get!(RefreshToken, parent.digest), parent)
    assert {:ok, stored} = RefreshStore.get(parent.digest)
    assert stored.successor.token == rotated.token
  end

  test "credential actions reject a different Session's Client, Human, or family", ctx do
    %{principal: other_human} = human_fixture()

    {:ok, %{client: other_client}} =
      Ankole.OIDC.create_client(%{
        name: "Other RP",
        type: "public",
        enabled: true,
        allowed_models: %{},
        allowed_group_ids: [],
        redirect_uris: ["https://other.example/callback"],
        scopes: ["openid"]
      })

    {:ok, other_session} = Ankole.OIDCFixtures.session(other_human.uid, other_client.id, "openid")

    for attrs <- [
          Map.put(code_attrs(ctx.session), :client_id, other_client.id),
          Map.put(code_attrs(ctx.session), :principal_uid, other_human.uid)
        ] do
      assert {:error, rejected} =
               Repo.transact(fn ->
                 Ankole.Ash.create(AuthorizationCode, :issue_in_tx, attrs)
               end)

      assert errors_on(rejected).session_id == ["does not exist"]
    end

    assert Repo.aggregate(AuthorizationCode, :count) == 0
    issued = refresh(ctx.session)
    token = Repo.get!(RefreshToken, Attesto.Secret.hash(issued.token))

    attrs =
      Map.take(token, [
        :family_id,
        :generation,
        :client_id,
        :principal_uid,
        :session_id,
        :scope,
        :context,
        :expires_at
      ])
      |> Map.put(:digest, "foreign-binding")
      |> Map.put(:generation, 1)

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.create(
                 RefreshToken,
                 :issue_in_tx,
                 Map.merge(attrs, %{
                   session_id: other_session.id,
                   client_id: other_client.id,
                   principal_uid: other_human.uid,
                   scope: "openid",
                   context: %{
                     "subject" => other_human.uid,
                     "client_id" => other_client.id,
                     "scope" => ["openid"],
                     "claims" => %{"session_id" => other_session.id}
                   }
                 })
               )
             end)

    assert errors_on(rejected).family_id == ["does not exist"]
    assert Repo.aggregate(RefreshToken, :count) == 1
    Ankole.DataCase.assert_persisted_equal(Repo.get!(RefreshToken, token.digest), token)
    assert code(ctx.session).session_id == ctx.session.id
    other_code = code(other_session)
    assert {:ok, _} = CodeStore.take(other_code.digest)
    consumed = Repo.get!(AuthorizationCode, other_code.digest)

    assert {:error, rejected} =
             Repo.transact(fn ->
               Ankole.Ash.update(consumed, :finalize_in_tx, %{
                 family_id: issued.family_id,
                 replay_retain_until: DateTime.add(DateTime.utc_now(), 1800)
               })
             end)

    assert errors_on(rejected).family_id == ["does not exist"]

    Ankole.DataCase.assert_persisted_equal(
      Repo.get!(AuthorizationCode, other_code.digest),
      consumed
    )
  end

  defp code(session) do
    {:ok, code} =
      Repo.transact(fn ->
        Ankole.Ash.create(AuthorizationCode, :issue_in_tx, code_attrs(session))
      end)

    code
  end

  defp code_attrs(session),
    do: %{
      digest: Ankole.Ecto.UUIDv7.autogenerate(),
      session_id: session.id,
      client_id: session.client_id,
      principal_uid: session.principal_uid,
      redirect_uri: "https://rp.example/callback",
      scope: "openid",
      code_challenge: String.duplicate("a", 43),
      expires_at: DateTime.add(DateTime.utc_now(), 60)
    }

  # The code exchange issues the first token of a family in its transaction.
  defp refresh(session) do
    {:ok, issued} =
      Repo.transact(fn ->
        Attesto.RefreshToken.issue(
          RefreshStore,
          %{
            subject: session.principal_uid,
            client_id: session.client_id,
            scope: ["openid", "offline_access"],
            claims: %{"session_id" => session.id}
          },
          ttl: 2_592_000,
          family_ttl: 2_592_000
        )
      end)

    issued
  end
end
