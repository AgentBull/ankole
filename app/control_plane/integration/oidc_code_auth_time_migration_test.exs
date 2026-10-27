defmodule Ankole.OIDCCodeAuthTimeMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  @tenant "019a2b00-0000-7000-8000-000000000001"
  @migration 20_261_027_200_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @moduletag timeout: 180_000

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  test "the migration captures live code authentication time and rolls back without removing codes" do
    config = Ankole.Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(:database, "ankole_oidc_code_upgrade_#{System.unique_integer([:positive])}")
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
    assert auth_time_column() == []

    now = NaiveDateTime.utc_now()
    auth_time = 1_700_000_001
    sessions = legacy_sessions(now, auth_time)
    expires_at = NaiveDateTime.add(now, 300, :second)

    codes = %{
      valid: legacy_code(sessions.known, now, expires_at),
      unknown: legacy_code(sessions.unknown, now, expires_at),
      expired:
        legacy_code(
          sessions.known,
          NaiveDateTime.add(now, -600, :second),
          NaiveDateTime.add(now, -300, :second)
        ),
      consumed:
        legacy_code(sessions.known, now, expires_at)
        |> Map.merge(%{consumed_at: now, finalized: true, replay_retain_until: expires_at})
    }

    assert {4, nil} = UpgradeRepo.insert_all("oidc_authorization_codes", Map.values(codes))

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    assert auth_time_column() == [["bigint", "YES"]]

    actual =
      UpgradeRepo
      |> SQL.query!("SELECT digest, auth_time FROM oidc_authorization_codes")
      |> Map.fetch!(:rows)
      |> Map.new(fn [digest, time] -> {digest, time} end)

    assert actual == %{
             codes.valid.digest => auth_time,
             codes.unknown.digest => nil,
             codes.expired.digest => nil,
             codes.consumed.digest => nil
           }

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :down, to: @migration, log: false) == [
             @migration
           ]

    assert auth_time_column() == []

    digests = codes |> Map.values() |> Enum.map(&[&1.digest]) |> MapSet.new()

    assert UpgradeRepo
           |> SQL.query!("SELECT digest FROM oidc_authorization_codes")
           |> Map.fetch!(:rows)
           |> MapSet.new() == digests
  end

  defp auth_time_column do
    SQL.query!(UpgradeRepo, """
    SELECT data_type, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'oidc_authorization_codes'
      AND column_name = 'auth_time'
    """).rows
  end

  defp legacy_sessions(now, auth_time) do
    subject = Ankole.Ecto.UUIDv7.autogenerate()
    browser_id = Ankole.Ecto.UUIDv7.autogenerate()
    authentication_id = Ankole.Ecto.UUIDv7.autogenerate()
    expiry = NaiveDateTime.add(now, 86_400, :second)
    tenant = Ecto.UUID.dump!(@tenant)

    UpgradeRepo.insert_all("principals", [
      %{
        tenant_id: tenant,
        uid: subject,
        type: "human",
        membership: "member",
        status: "active",
        display_name: "Legacy code user",
        access_version: 1,
        inserted_at: now,
        updated_at: now
      }
    ])

    UpgradeRepo.insert_all("human_users", [
      %{tenant_id: tenant, principal_uid: subject, inserted_at: now, updated_at: now}
    ])

    UpgradeRepo.insert_all("browser_sessions", [
      %{id: Ecto.UUID.dump!(browser_id), expires_at: expiry, inserted_at: now, updated_at: now}
    ])

    UpgradeRepo.insert_all("browser_authentications", [
      %{
        id: Ecto.UUID.dump!(authentication_id),
        browser_id: Ecto.UUID.dump!(browser_id),
        tenant_id: tenant,
        subject_id: subject,
        provider_id: "legacy",
        external_id: subject,
        purpose: "oauth",
        revision: 1,
        csrf_token: Attesto.Secret.generate(),
        challenge_started_at: now,
        authenticated_at: now,
        expires_at: expiry,
        inserted_at: now,
        updated_at: now
      }
    ])

    Map.new([known: auth_time, unknown: nil], fn {kind, time} ->
      client_id = Ankole.Ecto.UUIDv7.autogenerate()
      session_id = Ankole.Ecto.UUIDv7.autogenerate()

      UpgradeRepo.insert_all("oidc_clients", [
        %{
          id: Ecto.UUID.dump!(client_id),
          tenant_id: tenant,
          name: "Legacy code RP #{kind}",
          client_type: "public",
          redirect_uris: ["https://legacy.example/callback"],
          scopes: ["openid"],
          inserted_at: now,
          updated_at: now
        }
      ])

      UpgradeRepo.insert_all("oidc_sessions", [
        %{
          id: Ecto.UUID.dump!(session_id),
          tenant_id: tenant,
          client_id: Ecto.UUID.dump!(client_id),
          principal_uid: subject,
          browser_id: Ecto.UUID.dump!(browser_id),
          authentication_id: Ecto.UUID.dump!(authentication_id),
          authentication_revision: 1,
          access_version: 1,
          provider_id: "legacy",
          auth_time: time,
          expires_at: expiry,
          inserted_at: now,
          updated_at: now
        }
      ])

      {kind, %{client_id: client_id, session_id: session_id, subject: subject}}
    end)
  end

  defp legacy_code(session, now, expires_at) do
    raw = Attesto.Secret.generate()
    digest = :crypto.hash(:sha256, raw) |> Base.url_encode64(padding: false)

    %{
      digest: digest,
      tenant_id: Ecto.UUID.dump!(@tenant),
      client_id: Ecto.UUID.dump!(session.client_id),
      principal_uid: session.subject,
      session_id: Ecto.UUID.dump!(session.session_id),
      redirect_uri: "https://legacy.example/callback",
      scope: "openid",
      code_challenge:
        :crypto.hash(:sha256, String.duplicate("v", 43)) |> Base.url_encode64(padding: false),
      expires_at: expires_at,
      consumed_at: nil,
      finalized: false,
      replay_retain_until: nil,
      inserted_at: now
    }
  end
end
