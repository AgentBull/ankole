defmodule Ankole.OIDCProtocolUpgradeTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Ankole.OIDC.{RefreshStore, RefreshToken, RefreshTokenFamily}
  @tenant "019a2b00-0000-7000-8000-000000000001"
  @migration 20_261_021_131_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @moduletag timeout: 180_000

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  test "an existing refresh credential keeps its digest and deadline and rotates through the real store" do
    config = Ankole.Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(:database, "ankole_oidc_upgrade_#{System.unique_integer([:positive])}")
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:log, false)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    {:ok, pid} = UpgradeRepo.start_link(config)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      assert :ok = Ecto.Adapters.Postgres.storage_down(config)
    end)

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration - 1, log: false)

    subject = Ankole.Ecto.UUIDv7.autogenerate()

    expiry =
      DateTime.from_unix!((System.system_time(:second) + 2_592_000) * 1_000_000, :microsecond)

    now = NaiveDateTime.utc_now()

    UpgradeRepo.insert_all("principals", [
      %{
        tenant_id: Ecto.UUID.dump!(@tenant),
        uid: subject,
        type: "human",
        status: "active",
        display_name: "Legacy OIDC user",
        access_version: 1,
        inserted_at: now,
        updated_at: now
      }
    ])

    UpgradeRepo.insert_all("human_users", [
      %{
        tenant_id: Ecto.UUID.dump!(@tenant),
        principal_uid: subject,
        inserted_at: now,
        updated_at: now
      }
    ])

    client_id = Ankole.Ecto.UUIDv7.autogenerate()

    UpgradeRepo.insert_all("oidc_clients", [
      %{
        id: Ecto.UUID.dump!(client_id),
        tenant_id: Ecto.UUID.dump!(@tenant),
        name: "Legacy RP",
        client_type: "public",
        redirect_uris: ["https://legacy.example/callback"],
        scopes: ["openid", "offline_access"],
        inserted_at: now,
        updated_at: now
      }
    ])

    browser_id = Ankole.Ecto.UUIDv7.autogenerate()
    authentication_id = Ankole.Ecto.UUIDv7.autogenerate()

    UpgradeRepo.insert_all("browser_sessions", [
      %{
        id: Ecto.UUID.dump!(browser_id),
        expires_at: DateTime.to_naive(expiry),
        inserted_at: now,
        updated_at: now
      }
    ])

    UpgradeRepo.insert_all("browser_authentications", [
      %{
        id: Ecto.UUID.dump!(authentication_id),
        browser_id: Ecto.UUID.dump!(browser_id),
        tenant_id: Ecto.UUID.dump!(@tenant),
        subject_id: subject,
        provider_id: "legacy",
        external_id: subject,
        purpose: "oauth",
        revision: 1,
        csrf_token: Attesto.Secret.generate(),
        expires_at: DateTime.to_naive(expiry),
        inserted_at: now,
        updated_at: now
      }
    ])

    session_id = Ankole.Ecto.UUIDv7.autogenerate()

    UpgradeRepo.insert_all("oidc_sessions", [
      %{
        id: Ecto.UUID.dump!(session_id),
        tenant_id: Ecto.UUID.dump!(@tenant),
        client_id: Ecto.UUID.dump!(client_id),
        principal_uid: subject,
        browser_id: Ecto.UUID.dump!(browser_id),
        authentication_id: Ecto.UUID.dump!(authentication_id),
        authentication_revision: 1,
        access_version: 1,
        provider_id: "legacy",
        expires_at: DateTime.to_naive(expiry),
        inserted_at: now,
        updated_at: now
      }
    ])

    raw = Attesto.Secret.generate()
    digest = :crypto.hash(:sha256, raw) |> Base.url_encode64(padding: false)

    SQL.query!(
      UpgradeRepo,
      """
      INSERT INTO oidc_refresh_tokens
        (digest, client_id, principal_uid, scope, session_id, tenant_id,
         issued_at, absolute_expires_at, inserted_at, updated_at)
      VALUES ($1, $2::text::uuid, $3, 'openid offline_access', $4::text::uuid,
        $5::text::uuid, now(), $6, now(), now())
      """,
      [digest, client_id, subject, session_id, @tenant, DateTime.to_naive(expiry)]
    )

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    assert UpgradeRepo.get!(RefreshToken, digest).digest == digest

    assert DateTime.to_unix(UpgradeRepo.get!(RefreshTokenFamily, digest).family_expires_at) ==
             DateTime.to_unix(expiry)

    previous = Ankole.Repo.get_dynamic_repo()

    try do
      Ankole.Repo.put_dynamic_repo(pid)

      Ankole.Repo.with_tenant(@tenant, fn ->
        assert {:ok, rotated} =
                 Attesto.RefreshToken.rotate(RefreshStore, raw,
                   client_id: client_id,
                   ttl: 2_592_000
                 )

        assert rotated.family_id == digest
        assert rotated.generation == 1
        assert rotated.expires_at == DateTime.to_unix(expiry)

        assert {:ok, retried} =
                 Attesto.RefreshToken.rotate(RefreshStore, raw,
                   client_id: client_id,
                   ttl: 2_592_000
                 )

        assert retried.token == rotated.token
      end)
    after
      Ankole.Repo.put_dynamic_repo(previous)
    end
  end
end
