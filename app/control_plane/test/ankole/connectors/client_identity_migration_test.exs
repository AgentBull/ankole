defmodule Ankole.Connectors.ClientIdentityMigrationTest do
  use Ankole.DataCase, async: false

  test "the migration reads existing row-bound ciphertext and retains client uniqueness across tenants" do
    path =
      Path.expand(
        "../../../priv/repo/migrations/20261104030000_keep_connector_oauth_client_identity.exs",
        __DIR__
      )

    unless Code.ensure_loaded?(Ankole.Repo.Migrations.KeepConnectorOAuthClientIdentity),
      do: Code.require_file(path)

    schema = "connector_client_upgrade_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}, public")

    Repo.query!("""
    CREATE TABLE connector_auth_configs (
      id uuid PRIMARY KEY, tenant_id uuid NOT NULL, plugin_id text NOT NULL,
      platform_application text, sealed_secret text NOT NULL, status text NOT NULL DEFAULT 'active'
    )
    """)

    tenant = Repo.tenant_id!()

    for {client, application} <- [
          {"identity-client", "slack-client:identity-client"},
          {"bot-client", "slack:A-BOT"},
          {"", "slack:FIRST-BOT-ONLY"},
          {"", "slack:SECOND-BOT-ONLY"}
        ] do
      id = Ankole.Kernel.gen_uuid_v7()

      {:ok, sealed} =
        Ankole.SecretKeyBase.seal(
          Torque.encode!(%{"clientID" => client, "clientSecret" => "stored-secret"}),
          "connector_auth_config",
          [tenant, id]
        )

      Repo.query!(
        "INSERT INTO connector_auth_configs (id,tenant_id,plugin_id,platform_application,sealed_secret) VALUES ($1::text::uuid,$2::text::uuid,'slack',$3,$4)",
        [id, tenant, application, sealed]
      )
    end

    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_104_030_000,
      Ankole.Repo.Migrations.KeepConnectorOAuthClientIdentity,
      :forward,
      :up,
      :up,
      log: false
    )

    assert Repo.query!(
             "SELECT platform_client_id FROM connector_auth_configs ORDER BY platform_client_id"
           ).rows == [["bot-client"], ["identity-client"], [nil], [nil]]

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "connector_auth_configs_active_platform_client_uidx"}
            }} =
             Repo.query(
               "INSERT INTO connector_auth_configs (id,tenant_id,plugin_id,platform_client_id,sealed_secret) VALUES ($1::text::uuid,$2::text::uuid,'slack','bot-client','unused')",
               [Ankole.Kernel.gen_uuid_v7(), Ankole.Kernel.gen_uuid_v7()],
               mode: :savepoint
             )
  end
end
