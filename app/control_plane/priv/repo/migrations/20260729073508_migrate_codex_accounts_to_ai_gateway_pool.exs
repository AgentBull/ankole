defmodule Ankole.Repo.Migrations.MigrateCodexAccountsToAiGatewayPool do
  use Ecto.Migration

  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.AIGateway.Providers
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SecretKeyBase

  @chatgpt_provider_id "chatgpt-subscription"
  @chatgpt_base_url "https://chatgpt.com/backend-api/codex"
  @legacy_connection_credential_fields %{
    "azure_openai" => ~w(auth_scheme),
    "claude" => ~w(auth_mode),
    "xiaomi_mimo" => ~w(auth_mode)
  }

  def up do
    alter table(:ai_gateway_providers) do
      add(:credential_pool, :map,
        null: false,
        default: %{"strategy" => "fill_first", "entries" => []}
      )
    end

    flush()

    migrate_data(repo())

    execute("DROP INDEX IF EXISTS background_agent_jobs_codex_account_status_index")

    alter table(:background_agent_jobs) do
      remove(:codex_account_id)
    end

    drop(table(:codex_accounts))

    execute(
      "ALTER TABLE ai_gateway_providers DROP CONSTRAINT IF EXISTS ai_gateway_providers_encrypted_options_object"
    )

    alter table(:ai_gateway_providers) do
      remove(:encrypted_options)
    end

    create constraint(:ai_gateway_providers, :ai_gateway_providers_credential_pool_object,
             check: "jsonb_typeof(credential_pool) = 'object'"
           )
  end

  def down do
    raise "AIGateway credential-pool migration is a flag-day migration and cannot be reversed"
  end

  @doc false
  def migrate_data(repo) do
    migrate_provider_credentials(repo)
    chatgpt_provider_id = migrate_codex_accounts(repo)
    migrate_coding_profiles(repo, chatgpt_provider_id)

    repo.query!(
      "UPDATE background_agent_jobs SET metadata = metadata - 'codex_subscription' - 'codex_aigateway'",
      []
    )

    :ok
  end

  defp migrate_provider_credentials(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT id::text, provider_id, provider_kind, connection_options, encrypted_options
        FROM ai_gateway_providers
        ORDER BY provider_id
        """,
        []
      )

    Enum.each(rows, fn [
                         row_id,
                         provider_id,
                         provider_kind,
                         connection_options,
                         encrypted_options
                       ] ->
      {legacy_credential, connection_options} =
        take_legacy_connection_credential(provider_kind, connection_options)

      entries =
        case decrypt_provider_options(row_id, encrypted_options) do
          {:ok, options} ->
            case Map.merge(options, legacy_credential) do
              credential when map_size(credential) > 0 ->
                credential_entry(row_id, credential)

              _empty ->
                anonymous_credential_entry(row_id, provider_kind)
            end

          {:error, _reason} ->
            [
              invalid_entry_with_credential(
                row_id,
                "Default",
                "provider_credential_decrypt_failed",
                legacy_credential
              )
            ]
        end

      update_pool(repo, row_id, %{"strategy" => "fill_first", "entries" => entries})
      update_connection_options(repo, row_id, connection_options)

      if provider_id == "" do
        raise "invalid empty AIGateway provider id during credential migration"
      end
    end)
  end

  defp credential_entry(row_id, credential) do
    credential_id = Ankole.Ecto.UUIDv7.autogenerate()

    case Crypto.seal(credential, row_id, "credential:#{credential_id}") do
      {:ok, ciphertext} ->
        [
          %{
            "id" => credential_id,
            "label" => "Default",
            "priority" => 0,
            "source" => "migration",
            "disabled_at" => nil,
            "encrypted_credential" => ciphertext
          }
        ]

      {:error, _reason} ->
        [invalid_entry("Default", "provider_credential_encrypt_failed")]
    end
  end

  defp take_legacy_connection_credential(provider_kind, connection_options)
       when is_map(connection_options) do
    fields = Map.get(@legacy_connection_credential_fields, provider_kind, [])
    {Map.take(connection_options, fields), Map.drop(connection_options, fields)}
  end

  defp take_legacy_connection_credential(_provider_kind, _connection_options), do: {%{}, %{}}

  defp anonymous_credential_entry(row_id, provider_kind) do
    with {:ok, definition} <- Providers.fetch(provider_kind),
         false <- Providers.credential_required?(definition),
         credential_id <- Ankole.Ecto.UUIDv7.autogenerate(),
         {:ok, ciphertext} <- Crypto.seal(%{}, row_id, "credential:#{credential_id}") do
      [
        %{
          "id" => credential_id,
          "label" => "Default",
          "priority" => 0,
          "source" => "migration",
          "disabled_at" => nil,
          "encrypted_credential" => ciphertext
        }
      ]
    else
      _reason -> []
    end
  end

  defp migrate_codex_accounts(repo) do
    %{rows: accounts} =
      repo.query!(
        """
        SELECT account_id, name, encrypted_auth_json, updated_at
        FROM codex_accounts
        ORDER BY lower(name), account_id
        """,
        []
      )

    if accounts == [] and not legacy_coding_profiles?(repo) do
      nil
    else
      {row_id, provider_id, existing_pool} = chatgpt_provider(repo)

      migrated_entries =
        accounts
        |> Enum.with_index()
        |> Enum.map(fn {[account_id, name, encrypted_auth_json, updated_at], priority} ->
          migrate_codex_account(
            row_id,
            account_id,
            name,
            encrypted_auth_json,
            updated_at,
            priority
          )
        end)

      pool = %{
        "strategy" => Map.get(existing_pool, "strategy", "fill_first"),
        "entries" => Map.get(existing_pool, "entries", []) ++ migrated_entries
      }

      update_pool(repo, row_id, pool)
      provider_id
    end
  end

  defp legacy_coding_profiles?(repo) do
    repo.query!(
      """
      SELECT EXISTS (
        SELECT 1
        FROM agents
        WHERE jsonb_typeof(options #> '{ai_agent,models,coding}') = 'object'
          AND options #> '{ai_agent,models,coding}' ? 'codex_account_id'
      )
      """,
      []
    ).rows == [[true]]
  end

  defp chatgpt_provider(repo) do
    case repo.query!(
           """
           SELECT id::text, provider_id, credential_pool
           FROM ai_gateway_providers
           WHERE provider_kind = 'chatgpt_subscription'
           ORDER BY provider_id
           LIMIT 1
           """,
           []
         ).rows do
      [[row_id, provider_id, pool]] ->
        {row_id, provider_id, pool}

      [] ->
        row_id = Ankole.Ecto.UUIDv7.autogenerate()
        provider_id = available_chatgpt_provider_id(repo)
        pool = %{"strategy" => "fill_first", "entries" => []}

        repo.query!(
          """
          INSERT INTO ai_gateway_providers
            (id, provider_id, provider_kind, base_url, connection_options,
             encrypted_options, credential_pool, inserted_at, updated_at)
          VALUES (($1::text)::uuid, $2, 'chatgpt_subscription', $3, '{}'::jsonb,
                  '{}'::jsonb, $4::jsonb, now(), now())
          """,
          [row_id, provider_id, @chatgpt_base_url, pool]
        )

        {row_id, provider_id, pool}
    end
  end

  defp available_chatgpt_provider_id(repo) do
    existing =
      repo.query!(
        "SELECT provider_id FROM ai_gateway_providers WHERE provider_id LIKE $1",
        ["#{@chatgpt_provider_id}%"]
      ).rows
      |> MapSet.new(fn [provider_id] -> provider_id end)

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn
      0 ->
        if MapSet.member?(existing, @chatgpt_provider_id), do: nil, else: @chatgpt_provider_id

      suffix ->
        candidate = "#{@chatgpt_provider_id}-#{suffix}"
        if MapSet.member?(existing, candidate), do: nil, else: candidate
    end)
  end

  defp migrate_codex_account(
         provider_row_id,
         account_id,
         name,
         encrypted_auth_json,
         updated_at,
         priority
       ) do
    credential_id = Ankole.Ecto.UUIDv7.autogenerate()

    with {:ok, auth_json} <- unseal_codex_auth(encrypted_auth_json, account_id),
         {:ok, auth} <- Ankole.JSON.decode(auth_json),
         {:ok, credential} <- codex_credential(auth, account_id, updated_at),
         {:ok, ciphertext} <-
           Crypto.seal(credential, provider_row_id, "credential:#{credential_id}") do
      %{
        "id" => credential_id,
        "label" => name,
        "priority" => priority,
        "source" => "migration",
        "disabled_at" => nil,
        "encrypted_credential" => ciphertext
      }
    else
      {:error, _reason} ->
        invalid_entry(name, "codex_account_migration_failed", priority, credential_id)
    end
  end

  defp codex_credential(%{"tokens" => tokens} = auth, stored_account_id, updated_at)
       when is_map(tokens) do
    access_token = text(tokens["access_token"])
    refresh_token = text(tokens["refresh_token"])
    id_token = text(tokens["id_token"])
    account_id = text(tokens["account_id"]) || text(stored_account_id)

    if Enum.all?([access_token, refresh_token, id_token, account_id], &is_binary/1) do
      claims = jwt_claims(id_token)
      auth_claims = Map.get(claims, "https://api.openai.com/auth", %{})

      {:ok,
       %{
         "auth_type" => "oauth",
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "id_token" => id_token,
         "account_id" => account_id,
         "plan_type" =>
           text(auth_claims["chatgpt_plan_type"]) ||
             text(claims["chatgpt_plan_type"]),
         "email" => text(claims["email"]),
         "last_refresh" => last_refresh(auth["last_refresh"], updated_at)
       }
       |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    else
      {:error, :invalid_codex_tokens}
    end
  end

  defp codex_credential(_auth, _stored_account_id, _updated_at),
    do: {:error, :invalid_codex_auth}

  defp migrate_coding_profiles(_repo, nil), do: :ok

  defp migrate_coding_profiles(repo, provider_id) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT uid, options
        FROM agents
        WHERE jsonb_typeof(options #> '{ai_agent,models,coding}') = 'object'
          AND options #> '{ai_agent,models,coding}' ? 'codex_account_id'
        """,
        []
      )

    Enum.each(rows, fn [uid, options] ->
      coding = get_in(options, ["ai_agent", "models", "coding"])
      provider_options = %{"reasoningEffort" => text(coding["model_reasoning_effort"]) || "high"}

      provider_options =
        if coding["fast_mode"] == true do
          Map.put(provider_options, "serviceTier", "priority")
        else
          provider_options
        end

      migrated = %{
        "provider_id" => provider_id,
        "model" => text(coding["model"]) || "gpt-5.6-sol",
        "provider_options" => provider_options
      }

      new_options = put_in(options, ["ai_agent", "models", "coding"], migrated)

      repo.query!("UPDATE agents SET options = $2::jsonb, updated_at = now() WHERE uid = $1", [
        uid,
        new_options
      ])
    end)
  end

  defp decrypt_provider_options(_row_id, options) when options in [nil, %{}], do: {:ok, %{}}

  defp decrypt_provider_options(row_id, options) when is_map(options) do
    Enum.reduce_while(options, {:ok, %{}}, fn
      {key, ciphertext}, {:ok, acc} when is_binary(key) and is_binary(ciphertext) ->
        case Crypto.unseal(ciphertext, row_id, key) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_provider_encrypted_options}}
    end)
  end

  defp unseal_codex_auth(ciphertext, account_id)
       when is_binary(ciphertext) and is_binary(account_id) do
    with {:ok, secret} <- SecretKeyBase.fetch(),
         key <-
           NativeKernel.derive_key(
             secret,
             "codex_account_auth",
             "codex_accounts:#{account_id}"
           ),
         auth_json when is_binary(auth_json) <- NativeKernel.aead_decrypt(ciphertext, key) do
      {:ok, auth_json}
    else
      {:error, reason} -> {:error, reason}
      _value -> {:error, :codex_auth_decrypt_failed}
    end
  end

  defp update_pool(repo, row_id, pool) do
    repo.query!(
      """
      UPDATE ai_gateway_providers
      SET credential_pool = $2::jsonb, updated_at = now()
      WHERE id::text = $1
      """,
      [row_id, pool]
    )
  end

  defp update_connection_options(repo, row_id, connection_options) do
    repo.query!(
      """
      UPDATE ai_gateway_providers
      SET connection_options = $2::jsonb, updated_at = now()
      WHERE id::text = $1
      """,
      [row_id, connection_options]
    )
  end

  defp invalid_entry_with_credential(row_id, label, reason, credential)
       when map_size(credential) > 0 do
    entry = invalid_entry(label, reason)

    case Crypto.seal(credential, row_id, "credential:#{entry["id"]}") do
      {:ok, ciphertext} -> Map.put(entry, "encrypted_credential", ciphertext)
      {:error, _reason} -> entry
    end
  end

  defp invalid_entry_with_credential(_row_id, label, reason, _credential),
    do: invalid_entry(label, reason)

  defp invalid_entry(label, reason, priority \\ 0, credential_id \\ nil) do
    %{
      "id" => credential_id || Ankole.Ecto.UUIDv7.autogenerate(),
      "label" => label,
      "priority" => priority,
      "source" => "migration",
      "disabled_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
      "reauth_required" => true,
      "migration_error" => reason
    }
  end

  defp jwt_claims(value) when is_binary(value) do
    with [_header, payload, _signature] <- String.split(value, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Ankole.JSON.decode(decoded) do
      claims
    else
      _error -> %{}
    end
  end

  defp jwt_claims(_value), do: %{}

  defp last_refresh(value, _updated_at) when is_binary(value) and value != "", do: value

  defp last_refresh(_value, %NaiveDateTime{} = updated_at),
    do: updated_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp last_refresh(_value, %DateTime{} = updated_at), do: DateTime.to_iso8601(updated_at)

  defp last_refresh(_value, _updated_at),
    do: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil
end
