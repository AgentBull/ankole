defmodule Ankole.Ecto.AIGatewayV2MigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo
  alias Ankole.SecretKeyBase

  @migration Ankole.Repo.Migrations.MigrateCodexAccountsToAiGatewayPool

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260729073508_migrate_codex_accounts_to_ai_gateway_pool.exs",
        __DIR__
      )
    )
  end

  setup tags do
    if tags[:legacy_fixture] do
      create_legacy_fixture()
    end

    :ok
  end

  @tag legacy_fixture: true
  test "migrates provider secrets, Codex accounts, Coding profiles, and Job metadata" do
    provider_row_id = Ankole.Ecto.UUIDv7.autogenerate()
    anonymous_provider_row_id = Ankole.Ecto.UUIDv7.autogenerate()
    corrupt_provider_row_id = Ankole.Ecto.UUIDv7.autogenerate()
    {:ok, encrypted_api_key} = Crypto.seal("sk-legacy", provider_row_id, "api_key")

    legacy_connection_credentials = [
      {Ankole.Ecto.UUIDv7.autogenerate(), "claude-legacy", "claude", "auth_mode", "oauth"},
      {Ankole.Ecto.UUIDv7.autogenerate(), "azure-legacy", "azure_openai", "auth_scheme",
       "bearer"},
      {Ankole.Ecto.UUIDv7.autogenerate(), "xiaomi-legacy", "xiaomi_mimo", "auth_mode",
       "auth_token"}
    ]

    Repo.query!(
      """
      INSERT INTO ai_gateway_providers
        (id, provider_id, provider_kind, base_url, connection_options,
         encrypted_options, credential_pool, inserted_at, updated_at)
      VALUES (($1::text)::uuid, 'openai-main', 'openai', 'https://api.openai.com/v1',
              '{}'::jsonb, $2::jsonb, $3::jsonb, now(), now())
      """,
      [
        provider_row_id,
        %{"api_key" => encrypted_api_key},
        %{"strategy" => "fill_first", "entries" => []}
      ]
    )

    Repo.query!(
      """
      INSERT INTO ai_gateway_providers
        (id, provider_id, provider_kind, base_url, connection_options,
         encrypted_options, credential_pool, inserted_at, updated_at)
      VALUES (($1::text)::uuid, 'claude-corrupt', 'claude',
              'https://api.anthropic.com',
              '{"auth_mode":"oauth","headers":{"X-Shared":"shared"}}'::jsonb,
              '{"api_key":"not-valid-ciphertext"}'::jsonb,
              $2::jsonb, now(), now())
      """,
      [
        corrupt_provider_row_id,
        %{"strategy" => "fill_first", "entries" => []}
      ]
    )

    Enum.each(
      legacy_connection_credentials,
      fn {row_id, provider_id, provider_kind, field, value} ->
        {:ok, ciphertext} = Crypto.seal("#{provider_id}-secret", row_id, "api_key")

        Repo.query!(
          """
          INSERT INTO ai_gateway_providers
            (id, provider_id, provider_kind, base_url, connection_options,
             encrypted_options, credential_pool, inserted_at, updated_at)
          VALUES (($1::text)::uuid, $2, $3, 'https://provider.example.test',
                  $4::jsonb, $5::jsonb, $6::jsonb, now(), now())
          """,
          [
            row_id,
            provider_id,
            provider_kind,
            %{field => value, "headers" => %{"X-Shared" => "shared"}},
            %{"api_key" => ciphertext},
            %{"strategy" => "fill_first", "entries" => []}
          ]
        )
      end
    )

    Repo.query!(
      """
      INSERT INTO ai_gateway_providers
        (id, provider_id, provider_kind, base_url, connection_options,
         encrypted_options, credential_pool, inserted_at, updated_at)
      VALUES (($1::text)::uuid, 'compatible-anonymous', 'openai_compatible',
              'https://compatible.example.test/v1', '{}'::jsonb, '{}'::jsonb,
              $2::jsonb, now(), now())
      """,
      [
        anonymous_provider_row_id,
        %{"strategy" => "fill_first", "entries" => []}
      ]
    )

    insert_codex_account(
      "account-valid",
      "A valid",
      codex_ciphertext("account-valid", %{
        "tokens" => %{
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "account_id" => "account-valid",
          "id_token" =>
            jwt(%{
              "email" => "operator@example.com",
              "https://api.openai.com/auth" => %{"chatgpt_plan_type" => "pro"}
            })
        },
        "last_refresh" => "2026-07-28T12:00:00Z"
      })
    )

    insert_codex_account(
      "account-partial",
      "B partial",
      codex_ciphertext("account-partial", %{
        "tokens" => %{
          "access_token" => "access-token",
          "account_id" => "account-partial"
        }
      })
    )

    insert_codex_account("account-corrupt", "C corrupt", "not-a-valid-ciphertext")

    Repo.query!(
      """
      INSERT INTO agents (uid, options, updated_at)
      VALUES (
        'agent-1',
        $1::jsonb,
        now()
      )
      """,
      [
        %{
          "unrelated" => true,
          "ai_agent" => %{
            "models" => %{
              "coding" => %{
                "codex_account_id" => "account-valid",
                "model" => "gpt-5.6-terra",
                "model_reasoning_effort" => "xhigh",
                "fast_mode" => true
              }
            }
          }
        }
      ]
    )

    Repo.query!("""
    INSERT INTO background_agent_jobs (id, metadata)
    VALUES (
      1,
      '{"codex_subscription":true,"codex_aigateway":"legacy","keep":"fact"}'::jsonb
    )
    """)

    assert :ok = @migration.migrate_data(Repo)

    [[provider_pool]] =
      Repo.query!(
        "SELECT credential_pool FROM ai_gateway_providers WHERE provider_id = 'openai-main'"
      ).rows

    assert [provider_entry] = provider_pool["entries"]
    assert provider_entry["source"] == "migration"

    assert {:ok, %{"api_key" => "sk-legacy"}} =
             Crypto.unseal(
               provider_entry["encrypted_credential"],
               provider_row_id,
               "credential:#{provider_entry["id"]}"
             )

    [[anonymous_pool]] =
      Repo.query!(
        "SELECT credential_pool FROM ai_gateway_providers WHERE provider_id = 'compatible-anonymous'"
      ).rows

    assert [anonymous_entry] = anonymous_pool["entries"]

    assert {:ok, %{}} =
             Crypto.unseal(
               anonymous_entry["encrypted_credential"],
               anonymous_provider_row_id,
               "credential:#{anonymous_entry["id"]}"
             )

    Enum.each(
      legacy_connection_credentials,
      fn {row_id, provider_id, _provider_kind, field, value} ->
        [[pool, connection_options]] =
          Repo.query!(
            """
            SELECT credential_pool, connection_options
            FROM ai_gateway_providers
            WHERE provider_id = $1
            """,
            [provider_id]
          ).rows

        assert [entry] = pool["entries"]
        assert connection_options == %{"headers" => %{"X-Shared" => "shared"}}
        expected_secret = "#{provider_id}-secret"

        assert {:ok,
                %{
                  "api_key" => ^expected_secret,
                  ^field => ^value
                }} =
                 Crypto.unseal(
                   entry["encrypted_credential"],
                   row_id,
                   "credential:#{entry["id"]}"
                 )
      end
    )

    [[corrupt_pool, corrupt_connection_options]] =
      Repo.query!("""
      SELECT credential_pool, connection_options
      FROM ai_gateway_providers
      WHERE provider_id = 'claude-corrupt'
      """).rows

    assert [corrupt_entry] = corrupt_pool["entries"]
    assert corrupt_entry["reauth_required"] == true
    assert corrupt_entry["migration_error"] == "provider_credential_decrypt_failed"
    assert corrupt_connection_options == %{"headers" => %{"X-Shared" => "shared"}}

    assert {:ok, %{"auth_mode" => "oauth"}} =
             Crypto.unseal(
               corrupt_entry["encrypted_credential"],
               corrupt_provider_row_id,
               "credential:#{corrupt_entry["id"]}"
             )

    [[chatgpt_row_id, chatgpt_provider_id, chatgpt_pool]] =
      Repo.query!("""
      SELECT id::text, provider_id, credential_pool
      FROM ai_gateway_providers
      WHERE provider_kind = 'chatgpt_subscription'
      """).rows

    assert chatgpt_provider_id == "chatgpt-subscription"
    assert [valid_entry, partial_entry, corrupt_entry] = chatgpt_pool["entries"]
    assert valid_entry["label"] == "A valid"
    assert valid_entry["priority"] == 0

    Enum.each(
      [{partial_entry, "B partial", 1}, {corrupt_entry, "C corrupt", 2}],
      fn {entry, label, priority} ->
        assert entry["label"] == label
        assert entry["priority"] == priority
        assert entry["reauth_required"] == true
        assert entry["migration_error"] == "codex_account_migration_failed"
        assert is_binary(entry["disabled_at"])
        refute Map.has_key?(entry, "encrypted_credential")
      end
    )

    assert {:ok, credential} =
             Crypto.unseal(
               valid_entry["encrypted_credential"],
               chatgpt_row_id,
               "credential:#{valid_entry["id"]}"
             )

    assert credential == %{
             "access_token" => "access-token",
             "account_id" => "account-valid",
             "auth_type" => "oauth",
             "email" => "operator@example.com",
             "id_token" =>
               jwt(%{
                 "email" => "operator@example.com",
                 "https://api.openai.com/auth" => %{"chatgpt_plan_type" => "pro"}
               }),
             "last_refresh" => "2026-07-28T12:00:00Z",
             "plan_type" => "pro",
             "refresh_token" => "refresh-token"
           }

    [[options]] = Repo.query!("SELECT options FROM agents WHERE uid = 'agent-1'").rows

    assert options["unrelated"] == true

    assert get_in(options, ["ai_agent", "models", "coding"]) == %{
             "model" => "gpt-5.6-terra",
             "provider_id" => chatgpt_provider_id,
             "provider_options" => %{
               "reasoningEffort" => "xhigh",
               "serviceTier" => "priority"
             }
           }

    assert [[%{"keep" => "fact"}]] =
             Repo.query!("SELECT metadata FROM background_agent_jobs WHERE id = 1").rows
  end

  @tag legacy_fixture: true
  test "preserves a dangling Coding profile as an empty ChatGPT pool" do
    Repo.query!("""
    INSERT INTO agents (uid, options, updated_at)
    VALUES (
      'agent-dangling',
      '{"ai_agent":{"models":{"coding":{"codex_account_id":"gone"}}}}'::jsonb,
      now()
    )
    """)

    assert :ok = @migration.migrate_data(Repo)

    assert [[provider_id, %{"entries" => [], "strategy" => "fill_first"}]] =
             Repo.query!("""
             SELECT provider_id, credential_pool
             FROM ai_gateway_providers
             WHERE provider_kind = 'chatgpt_subscription'
             """).rows

    assert [[coding]] =
             Repo.query!(
               "SELECT options #> '{ai_agent,models,coding}' FROM agents WHERE uid = 'agent-dangling'"
             ).rows

    assert coding == %{
             "model" => "gpt-5.6-sol",
             "provider_id" => provider_id,
             "provider_options" => %{"reasoningEffort" => "high"}
           }
  end

  test "current schema contains only the credential-pool contract" do
    columns =
      Repo.query!("""
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'ai_gateway_providers'
      """).rows
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.member?(columns, "credential_pool")
    refute MapSet.member?(columns, "encrypted_options")

    assert [[nil]] = Repo.query!("SELECT to_regclass('codex_accounts')").rows

    job_columns =
      Repo.query!("""
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'background_agent_jobs'
      """).rows
      |> List.flatten()
      |> MapSet.new()

    refute MapSet.member?(job_columns, "codex_account_id")

    assert [[constraint]] =
             Repo.query!("""
             SELECT pg_get_constraintdef(oid)
             FROM pg_constraint
             WHERE conname = 'ai_gateway_providers_credential_pool_object'
             """).rows

    assert constraint =~ "jsonb_typeof(credential_pool)"
  end

  test "refuses a lossy downgrade" do
    assert_raise RuntimeError, ~r/flag-day migration/, fn -> @migration.down() end
  end

  defp create_legacy_fixture do
    Repo.query!("""
    CREATE TEMPORARY TABLE ai_gateway_providers (
      id uuid PRIMARY KEY,
      provider_id text NOT NULL,
      provider_kind text NOT NULL,
      base_url text,
      connection_options jsonb NOT NULL,
      encrypted_options jsonb NOT NULL,
      credential_pool jsonb NOT NULL,
      inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE TEMPORARY TABLE codex_accounts (
      account_id text PRIMARY KEY,
      name text NOT NULL,
      encrypted_auth_json text NOT NULL,
      auth_hash text NOT NULL,
      updated_at timestamptz NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE TEMPORARY TABLE agents (
      uid text PRIMARY KEY,
      options jsonb NOT NULL,
      updated_at timestamptz NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE TEMPORARY TABLE background_agent_jobs (
      id bigint PRIMARY KEY,
      metadata jsonb NOT NULL
    ) ON COMMIT DROP
    """)
  end

  defp insert_codex_account(account_id, name, ciphertext) do
    Repo.query!(
      """
      INSERT INTO codex_accounts
        (account_id, name, encrypted_auth_json, auth_hash, updated_at)
      VALUES ($1, $2, $3, 'legacy-hash', '2026-07-28T12:00:00Z'::timestamptz)
      """,
      [account_id, name, ciphertext]
    )
  end

  defp codex_ciphertext(account_id, auth) do
    {:ok, secret} = SecretKeyBase.fetch()
    key = NativeKernel.derive_key(secret, "codex_account_auth", "codex_accounts:#{account_id}")
    NativeKernel.aead_encrypt(Ankole.JSON.encode!(auth), key)
  end

  defp jwt(claims) do
    payload = claims |> Ankole.JSON.encode!() |> Base.url_encode64(padding: false)
    "e30.#{payload}.signature"
  end
end
