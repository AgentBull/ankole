defmodule Ankole.OIDC.CleanupExpiredCredentialsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.OIDC
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.Jobs.CleanupExpiredCredentials
  alias Ankole.OIDC.RefreshToken
  alias Ankole.Repo

  test "the cleanup job deletes only expired codes and refresh tokens" do
    human = human_fixture()
    client_id = create_client!()
    now = DateTime.utc_now(:microsecond)

    expired_code = insert_code!(client_id, human.principal.uid, "expired-code", before(now))
    active_code = insert_code!(client_id, human.principal.uid, "active-code", after_now(now))

    expired_refresh =
      insert_refresh!(client_id, human.principal.uid, "expired-refresh", before(now))

    active_refresh =
      insert_refresh!(client_id, human.principal.uid, "active-refresh", after_now(now))

    assert :ok =
             CleanupExpiredCredentials.perform(%Oban.Job{
               id: System.unique_integer([:positive]),
               queue: "default",
               attempt: 1
             })

    refute Repo.get(AuthorizationCode, expired_code.digest)
    assert Repo.get(AuthorizationCode, active_code.digest)
    refute Repo.get(RefreshToken, expired_refresh.digest)
    assert Repo.get(RefreshToken, active_refresh.digest)
  end

  defp create_client! do
    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Cleanup Client",
        enabled: true,
        type: "public",
        redirect_uris: ["https://cleanup.example.test/callback"],
        scopes: ["openid"],
        allowed_group_ids: [],
        allowed_models: %{}
      })

    client.id
  end

  defp insert_code!(client_id, principal_uid, digest, expires_at) do
    %AuthorizationCode{}
    |> AuthorizationCode.changeset(%{
      digest: digest,
      client_id: client_id,
      principal_uid: principal_uid,
      redirect_uri: "https://cleanup.example.test/callback",
      scope: "openid",
      code_challenge_digest: "challenge",
      code_challenge_method: "S256",
      expires_at: expires_at
    })
    |> Repo.insert!()
  end

  defp insert_refresh!(client_id, principal_uid, digest, absolute_expires_at) do
    %RefreshToken{}
    |> RefreshToken.changeset(%{
      digest: digest,
      client_id: client_id,
      principal_uid: principal_uid,
      scope: "openid offline_access",
      issued_at: DateTime.add(absolute_expires_at, -60, :second),
      absolute_expires_at: absolute_expires_at
    })
    |> Repo.insert!()
  end

  defp before(now), do: DateTime.add(now, -1, :second)
  defp after_now(now), do: DateTime.add(now, 60, :second)
end
