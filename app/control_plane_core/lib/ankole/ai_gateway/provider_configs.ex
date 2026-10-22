defmodule Ankole.AIGateway.ProviderConfigs do
  @moduledoc """
  CRUD and projection service for operator-configured AIGateway providers.

  A provider row holds shared endpoint settings and an inline encrypted
  credential pool. Plaintext credential fields only leave through provider
  request construction and model metadata. Every Console/API shape goes
  through `projection/1`.

  The writes that read the current row lock it first and run as the generic
  actions of `Ankole.AIGateway.ProviderConfigs.Provider`.
  """

  require Ash.Query

  alias Ankole.Attrs
  alias Ecto.Adapters.SQL

  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs.Credentials
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers

  # A Provider is a site row. Its reference check reads the Agent model
  # profiles of every tenant.
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site

  @typedoc """
  Common result shape for provider-row writes and fetches.
  """
  @type provider_result :: {:ok, Provider.t()} | {:error, term()}

  @doc """
  Lists available provider kinds.
  """
  @spec list_provider_kinds() :: [map()]
  def list_provider_kinds do
    Enum.map(Providers.all(), &Providers.projection/1)
  end

  @doc """
  Lists configured provider projections without plaintext encrypted options.
  """
  @spec list_providers() :: [map()]
  def list_providers do
    Provider
    |> Ash.Query.sort(provider_id: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(&projection/1)
  end

  @doc """
  Lists active provider rows for runtime-facing catalogs.
  """
  @spec list_active_providers() :: [Provider.t()]
  def list_active_providers do
    Provider
    |> Ash.Query.filter(is_nil(disabled_at))
    |> Ash.Query.sort(provider_id: :asc)
    |> Ankole.Ash.read!()
  end

  @doc """
  Fetches a provider row by its operator-facing provider id.
  """
  @spec fetch_provider(String.t()) :: provider_result()
  def fetch_provider(provider_id) when is_binary(provider_id) do
    case Provider
         |> Ash.Query.filter(provider_id == ^Provider.normalize_id(provider_id))
         |> Ankole.Ash.read_one!() do
      %Provider{} = provider -> {:ok, provider}
      nil -> {:error, :not_found}
    end
  end

  def fetch_provider(_provider_id), do: {:error, :not_found}

  @doc """
  Fetches an active provider row.
  """
  @spec fetch_active_provider(String.t()) :: provider_result()
  def fetch_active_provider(provider_id) do
    with {:ok, %Provider{} = provider} <- fetch_provider(provider_id) do
      case provider.disabled_at do
        nil -> {:ok, provider}
        %DateTime{} -> {:error, :provider_disabled}
      end
    end
  end

  @doc """
  Returns whether one configured provider row speaks the Responses wire.

  The row referenced by the model reference holds the operator-configured
  connection options, so this reads them and delegates the judgment to
  `Providers.responses_endpoint?/2`. A missing, disabled, or re-kinded
  provider row declares nothing.
  """
  @spec responses_endpoint?(map()) :: boolean()
  def responses_endpoint?(%{
        "provider_id" => provider_id,
        "provider_kind" => provider_kind
      })
      when is_binary(provider_id) and is_binary(provider_kind) do
    case fetch_active_provider(provider_id) do
      {:ok, %Provider{provider_kind: ^provider_kind, connection_options: options}}
      when is_map(options) ->
        Providers.responses_endpoint?(provider_kind, options)

      _unavailable_or_changed ->
        false
    end
  end

  def responses_endpoint?(_model_ref), do: false

  @doc """
  Returns a safe projection for one provider.
  """
  @spec get_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def get_provider(provider_id) do
    with {:ok, provider} <- fetch_provider(provider_id) do
      {:ok, projection(provider)}
    end
  end

  @doc """
  Creates a provider row.
  """
  @spec create_provider(map()) :: provider_result()
  def create_provider(attrs) when is_map(attrs),
    do: Ankole.Ash.create(Provider, :create, %{input: attrs})

  @doc """
  Updates provider metadata and optionally its encrypted options.

  Encrypted option write semantics:

  - omitted: preserve existing encrypted option
  - `nil` or blank: clear that encrypted option
  - any other JSON-compatible value: replace that encrypted option
  """
  @spec update_provider(String.t(), map()) :: provider_result()
  def update_provider(provider_id, attrs) when is_map(attrs),
    do: change(provider_id, :configure, %{input: attrs})

  @doc "Applies a Console PUT to the provider named by the request path."
  def put_provider(provider_id, attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)
    body_id = Map.get(attrs, "provider_id")

    cond do
      not is_nil(body_id) and (not is_binary(body_id) or Provider.normalize_id(body_id) == "") ->
        {:error, :blank_id}

      not is_nil(body_id) and Provider.normalize_id(body_id) != provider_id ->
        {:error, :provider_id_mismatch}

      true ->
        attrs = Map.put(attrs, "provider_id", provider_id)

        case fetch_provider(provider_id) do
          {:ok, _provider} -> update_provider(provider_id, attrs)
          {:error, :not_found} -> create_provider(attrs)
        end
    end
  end

  @doc """
  Disables an active provider or deletes a provider that is already disabled.

  Both operations require the provider to have no Agent profile or Brain model references.
  """
  @spec delete_provider(String.t()) :: provider_result()
  def delete_provider(provider_id) when is_binary(provider_id),
    do: Ankole.Ash.run_action(Provider, :retire, %{provider_id: provider_id})

  @doc false
  # Runs the `:retire` action of the Provider resource.
  def retire(%{provider_id: provider_id}) do
    case lock_provider(provider_id) do
      nil -> {:error, :not_found}
      %Provider{disabled_at: nil} = provider -> Ankole.Ash.update(provider, :disable, %{})
      provider -> Ankole.Ash.destroy(provider, :remove)
    end
  end

  @doc """
  Re-enables a disabled provider and clears health from before it was disabled.

  Enabling an active provider returns it unchanged and preserves current
  credential health. A disabled provider whose kind or connection options are
  no longer valid is rejected instead of returning to service.
  """
  @spec enable_provider(String.t()) :: provider_result()
  def enable_provider(provider_id) when is_binary(provider_id),
    do: change(provider_id, :enable, %{})

  @doc """
  Selects, decrypts, and refreshes one provider credential.

  The request context can include `affinity_key` and an `exclude` list. The
  selected credential id is returned with the plaintext fields so asynchronous
  failure handling never has to guess which entry failed. A permanent refresh
  failure or HTTP 429 updates that entry's health and selects the next usable
  entry. Other refresh endpoint failures leave credential health unchanged.
  """
  @spec resolve_credential(Provider.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_credential(%Provider{} = provider, ctx \\ %{}) do
    with %Provider{} = current <-
           Provider |> Ash.Query.filter(id == ^provider.id) |> Ankole.Ash.read_one!() do
      pool = Credentials.credential_pool(current)
      entries = Map.get(pool, "entries", [])
      strategy = Map.get(pool, "strategy", "fill_first")
      affinity_key = context_value(ctx, :affinity_key)
      excluded = context_value(ctx, :exclude) || []
      resolve_credential(current, entries, strategy, affinity_key, excluded)
    else
      nil -> {:error, :not_found}
    end
  end

  defp resolve_credential(provider, entries, strategy, affinity_key, excluded) do
    with {:ok, selection} <-
           CredentialPool.select(provider.id, entries, strategy,
             affinity_key: affinity_key,
             exclude: excluded
           ),
         {:ok, credential} <- Credentials.decrypt_credential(provider, selection.entry) do
      selected = %{
        "id" => selection.credential_id,
        "label" => Map.get(selection.entry, "label"),
        "credential" => credential,
        "entry" => selection.entry,
        "available_count" => selection.available_count
      }

      case ChatGPTAuth.ensure_fresh(provider, selected) do
        {:ok, selected} ->
          {:ok, selected}

        {:error, {:chatgpt_refresh_permanent, _reason}} ->
          resolve_credential(provider, %{
            affinity_key: affinity_key,
            exclude: [selection.credential_id | excluded]
          })

        {:error, {:chatgpt_refresh_transient, 429, _headers, _reason}} ->
          resolve_credential(provider, %{
            affinity_key: affinity_key,
            exclude: [selection.credential_id | excluded]
          })

        {:error, {:chatgpt_refresh_transient, _status, _headers, _reason}} = error ->
          error

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Persists a cooldown only for the attributed credential revision."
  def put_credential_cooldown(row_id, credential, %DateTime{} = until, reason) do
    case Ankole.Ash.run_action(Provider, :put_cooldown, %{
           row_id: row_id,
           credential: credential,
           until: until,
           reason: reason
         }) do
      {:ok, _provider} -> :ok
      error -> error
    end
  end

  @doc false
  # Runs the `:put_cooldown` action of the Provider resource.
  def put_cooldown(%{row_id: row_id} = arguments) do
    case Provider
         |> Ash.Query.filter(id == ^row_id)
         |> Ash.Query.lock(:for_update)
         |> Ankole.Ash.read_one!() do
      nil -> {:ok, :unchanged}
      provider -> Ankole.Ash.update(provider, :cooldown, Map.delete(arguments, :row_id))
    end
  end

  @doc """
  Returns a runtime-safe connection config with one selected credential.

  The provider row may omit `base_url` and `transport` when the provider
  implementation has safe defaults. The returned map is the single shape used by
  provider dispatch and model catalog projections.
  """
  @spec runtime_connection(Provider.t()) :: {:ok, map()} | {:error, term()}
  def runtime_connection(%Provider{} = provider) do
    with {:ok, selected} <- resolve_credential(provider, %{}) do
      runtime_connection(provider, selected)
    end
  end

  @spec runtime_connection(Provider.t(), map()) :: {:ok, map()} | {:error, term()}
  def runtime_connection(%Provider{} = provider, %{"credential" => credential})
      when is_map(credential) do
    with {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         {:ok, options} <-
           Providers.normalize_connection_options(
             provider.provider_kind,
             provider.connection_options || %{}
           ),
         {:ok, base_url} <- runtime_base_url(provider, provider_kind) do
      {:ok,
       options
       |> Map.merge(credential)
       |> Map.put("base_url", base_url)}
    end
  end

  @doc """
  Adds one credential to a provider pool.

  The caller supplies plaintext credential fields only for this write. The
  returned provider struct still contains ciphertext, and callers must use
  `projection/1` before returning it through an API.
  """
  @spec add_credential(String.t(), map()) :: provider_result()
  def add_credential(provider_id, attrs) when is_binary(provider_id) and is_map(attrs),
    do: change(provider_id, :add_credential, %{input: attrs})

  @doc """
  Replaces the supplied fields of one pool credential.

  Omitted credential fields are preserved. A credential id cannot change.
  """
  @spec update_credential(String.t(), String.t(), map()) :: provider_result()
  def update_credential(provider_id, credential_id, attrs)
      when is_binary(provider_id) and is_binary(credential_id) and is_map(attrs),
      do: change(provider_id, :replace_credential, %{credential_id: credential_id, input: attrs})

  @doc """
  Deletes one credential from a provider pool.
  """
  @spec delete_credential(String.t(), String.t()) :: provider_result()
  def delete_credential(provider_id, credential_id)
      when is_binary(provider_id) and is_binary(credential_id),
      do: change(provider_id, :remove_credential, %{credential_id: credential_id})

  @doc """
  Changes the selection strategy without replacing credential entries.
  """
  @spec update_credential_strategy(String.t(), String.t()) :: provider_result()
  def update_credential_strategy(provider_id, strategy)
      when is_binary(provider_id) and is_binary(strategy),
      do: change(provider_id, :select_strategy, %{strategy: strategy})

  @doc """
  Runs an atomic read-modify-write for one credential.

  The callback runs after the provider row is locked. It receives the provider,
  the stored entry, and the latest plaintext credential. It can return
  `{:ok, credential}` to replace the encrypted value, `{:ok, :unchanged}` to
  keep it, or an error tuple. This is used for rotating refresh tokens, where
  releasing the row lock between the upstream exchange and the database write
  could consume the same refresh token twice. The write keeps the health
  revision because an automatic token refresh continues the same credential.
  """
  @spec update_credential_under_lock(
          String.t(),
          String.t(),
          (Provider.t(), map(), map() ->
             {:ok, map()} | {:ok, :unchanged} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def update_credential_under_lock(provider_id, credential_id, callback)
      when is_binary(provider_id) and is_binary(credential_id) and is_function(callback, 3) do
    Ankole.Ash.run_action(Provider, :rotate_credential, %{
      provider_id: provider_id,
      credential_id: credential_id,
      callback: callback
    })
  end

  @doc false
  # Runs the `:rotate_credential` action of the Provider resource.
  def rotate_credential(%{provider_id: provider_id, credential_id: credential_id} = arguments) do
    with %Provider{} = provider <- lock_provider(provider_id),
         {:ok, entry} <- Credentials.fetch_credential_entry(provider, credential_id),
         {:ok, credential} <- Credentials.decrypt_credential(provider, entry) do
      case arguments.callback.(provider, entry, credential) do
        {:ok, :unchanged} ->
          {:ok,
           %{
             "provider" => provider,
             "id" => credential_id,
             "entry" => entry,
             "credential" => credential
           }}

        {:ok, updated_credential} when is_map(updated_credential) ->
          with {:ok, provider} <-
                 Ankole.Ash.update(provider, :refresh_credential, %{
                   credential_id: credential_id,
                   credential: updated_credential
                 }),
               {:ok, entry} <- Credentials.fetch_credential_entry(provider, credential_id) do
            {:ok,
             %{
               "provider" => provider,
               "id" => credential_id,
               "entry" => entry,
               "credential" => updated_credential
             }}
          end

        {:error, _reason} = error ->
          error

        _value ->
          {:error, :invalid_credential_update}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Projects one provider without plaintext secrets.
  """
  @spec projection(Provider.t()) :: map()
  def projection(%Provider{} = provider) do
    %{
      "id" => provider.id,
      "provider_id" => provider.provider_id,
      "provider_kind" => provider.provider_kind,
      "base_url" => provider.base_url,
      "connection_options" => provider.connection_options || %{},
      "credential_pool" => credential_pool_projection(provider),
      "disabled_at" => provider.disabled_at && DateTime.to_iso8601(provider.disabled_at),
      "provider_metadata" => provider_metadata(provider.provider_kind)
    }
  end

  defp runtime_base_url(%Provider{base_url: base_url}, _provider_kind)
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, %{base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, _provider_kind), do: {:error, :missing_base_url}

  # Runs one update action on the locked row: the update reads the current
  # credential pool.
  defp change(provider_id, update, params),
    do:
      Ankole.Ash.run_action(Provider, :change, %{
        provider_id: provider_id,
        update: update,
        params: params
      })

  @doc false
  # Runs the `:change` action of the Provider resource.
  def change_locked(%{provider_id: provider_id, update: update, params: params}) do
    case lock_provider(provider_id) do
      nil -> {:error, :not_found}
      provider -> Ankole.Ash.update(provider, update, params)
    end
  end

  defp lock_provider(provider_id) do
    Provider
    |> Ash.Query.filter(provider_id == ^Provider.normalize_id(provider_id))
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  # Finds every agent model profile still pointing at this provider, returned as
  # "agent_uid:profile" labels. A non-empty list blocks the disable so an
  # operator cannot silently break agents that depend on the provider; profiles
  # live inside each agent's `options` JSON, so the database filters and expands
  # only matching JSONB profile entries.
  @doc false
  def provider_references(repo, provider_id) do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
        SELECT agent.uid || ':' || profile.key AS reference
        FROM agents AS agent
        CROSS JOIN LATERAL jsonb_each(
          CASE
            WHEN jsonb_typeof(agent.options #> '{ai_agent,models}') = 'object'
              THEN agent.options #> '{ai_agent,models}'
            ELSE '{}'::jsonb
          END
        ) AS profile(key, value)
        WHERE jsonb_path_query_array(
          agent.options,
          'lax $.ai_agent.models.*.provider_id'::jsonpath
        ) @> jsonb_build_array($1::text)
          AND profile.value @> jsonb_build_object('provider_id', $1::text)
        ORDER BY reference
        """,
        [provider_id]
      )

    with {:ok, brain_references} <-
           Ankole.Brain.Config.model_provider_references(repo, provider_id) do
      Enum.map(rows, fn [reference] -> reference end) ++ brain_references
    end
  end

  # API projections expose pool metadata, selected health, and a small set of
  # account facts. Token and API-key fields never leave this module.
  defp credential_pool_projection(%Provider{} = provider) do
    pool = Credentials.credential_pool(provider)
    entries = Map.get(pool, "entries", [])
    statuses = CredentialPool.statuses(provider.id, entries)

    %{
      "strategy" => Map.get(pool, "strategy", "fill_first"),
      "entries" =>
        Enum.map(entries, fn entry ->
          credential_id = Map.get(entry, "id")
          status = Map.get(statuses, credential_id, %{"status" => "dead"})

          account_projection =
            case Credentials.decrypt_credential(provider, entry) do
              {:ok, credential} ->
                Map.take(credential, [
                  "account_id",
                  "plan_type",
                  "email",
                  "last_refresh",
                  "auth_type"
                ])

              {:error, _reason} ->
                %{"reauth_required" => true}
            end

          entry
          |> Map.take([
            "id",
            "label",
            "priority",
            "source",
            "disabled_at",
            "reauth_required"
          ])
          |> Map.put("credential_present", is_binary(Map.get(entry, "encrypted_credential")))
          |> Map.merge(account_projection)
          |> Map.merge(status)
        end)
    }
  end

  defp context_value(ctx, key) when is_list(ctx), do: Keyword.get(ctx, key)

  defp context_value(ctx, key) when is_map(ctx) do
    Ankole.Attrs.get_truthy(ctx, key)
  end

  defp context_value(_ctx, _key), do: nil

  # Provider metadata is attached to configured rows so Console can render the
  # accepted options and capabilities without querying the registry separately.
  defp provider_metadata(provider_kind) do
    case Providers.fetch(provider_kind) do
      {:ok, provider_kind} ->
        provider_kind
        |> Providers.projection()
        |> Map.take([
          "capabilities",
          "settings"
        ])

      {:error, _reason} ->
        %{}
    end
  end
end
