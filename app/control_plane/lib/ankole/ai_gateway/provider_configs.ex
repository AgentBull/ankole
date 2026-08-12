defmodule Ankole.AIGateway.ProviderConfigs do
  @moduledoc """
  CRUD and projection service for operator-configured AIGateway providers.

  A provider row holds shared endpoint settings and an inline encrypted
  credential pool. Plaintext credential fields only leave through provider
  request construction and the live-check path. Every Console/API shape goes
  through `projection/1`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL

  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers
  alias Ankole.Repo

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
    |> order_by([provider], asc: provider.provider_id)
    |> Repo.all()
    |> Enum.map(&projection/1)
  end

  @doc """
  Lists active provider rows for runtime-facing catalogs.
  """
  @spec list_active_providers() :: [Provider.t()]
  def list_active_providers do
    Provider
    |> where([provider], is_nil(provider.disabled_at))
    |> order_by([provider], asc: provider.provider_id)
    |> Repo.all()
  end

  @doc """
  Fetches a provider row by its operator-facing provider id.
  """
  @spec fetch_provider(String.t()) :: provider_result()
  def fetch_provider(provider_id) when is_binary(provider_id) do
    case Repo.get_by(Provider, provider_id: normalize_id(provider_id)) do
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
  Returns whether the model's active provider connection declares the
  provider-hosted `web_search` tool.

  The write path already enforces that `hosted_web_search` pairs with a
  Responses endpoint, so this read checks only the stored declaration. A
  missing, disabled, or re-kinded provider row declares nothing.
  """
  @spec supports_hosted_web_search?(map()) :: boolean()
  def supports_hosted_web_search?(%{
        "provider_id" => provider_id,
        "provider_kind" => provider_kind
      })
      when is_binary(provider_id) and is_binary(provider_kind) do
    case fetch_active_provider(provider_id) do
      {:ok, %Provider{provider_kind: ^provider_kind, connection_options: options}}
      when is_map(options) ->
        Map.get(options, "hosted_web_search") == true

      _unavailable_or_changed ->
        false
    end
  end

  def supports_hosted_web_search?(_model_ref), do: false

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
  def create_provider(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      provider = %Provider{id: Ankole.Ecto.UUIDv7.autogenerate()}

      with {:ok, attrs} <- provider_attrs_for_write(attrs, provider) do
        provider
        |> Provider.changeset(attrs)
        |> repo.insert()
      end
    end)
  end

  @doc """
  Updates provider metadata and optionally its encrypted options.

  Encrypted option write semantics:

  - omitted: preserve existing encrypted option
  - `nil` or blank: clear that encrypted option
  - any other JSON-compatible value: replace that encrypted option
  """
  @spec update_provider(String.t(), map()) :: provider_result()
  def update_provider(provider_id, attrs) when is_map(attrs) do
    credential_pool_changed? =
      Map.has_key?(attrs, "credential_pool") or Map.has_key?(attrs, :credential_pool)

    result =
      Repo.transact(fn repo ->
        with %Provider{} = provider <- lock_provider(repo, provider_id),
             {:ok, attrs} <- provider_attrs_for_write(attrs, provider) do
          provider
          |> Provider.changeset(attrs)
          |> repo.update()
        else
          nil -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)

    case result do
      {:ok, %Provider{} = provider} when credential_pool_changed? ->
        clear_pool_health(provider)
        result

      _result ->
        result
    end
  end

  @doc """
  Disables an active provider or deletes a provider that is already disabled.

  Both operations require the provider to have no active model-profile references.
  """
  @spec delete_provider(String.t()) :: provider_result()
  def delete_provider(provider_id) when is_binary(provider_id) do
    Repo.transact(fn repo ->
      with %Provider{} = provider <- lock_provider(repo, provider_id),
           [] <- provider_references(repo, provider.provider_id) do
        case provider.disabled_at do
          nil ->
            provider
            |> Provider.changeset(%{disabled_at: DateTime.utc_now(:microsecond)})
            |> repo.update()

          %DateTime{} ->
            repo.delete(provider)
        end
      else
        nil -> {:error, :not_found}
        references when is_list(references) -> {:error, {:provider_in_use, references}}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Validates provider attrs without writing them.
  """
  @spec validate_provider(map()) :: :ok | {:error, term()}
  def validate_provider(attrs) when is_map(attrs) do
    provider = %Provider{id: Ankole.Ecto.UUIDv7.autogenerate()}

    with {:ok, attrs} <- provider_attrs_for_write(attrs, provider) do
      provider
      |> Provider.changeset(attrs)
      |> case do
        %{valid?: true} -> :ok
        changeset -> {:error, changeset}
      end
    end
  end

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
    pool = credential_pool(provider)
    entries = Map.get(pool, "entries", [])
    strategy = Map.get(pool, "strategy", "fill_first")
    affinity_key = context_value(ctx, :affinity_key)
    excluded = context_value(ctx, :exclude) || []

    resolve_credential(provider, entries, strategy, affinity_key, excluded)
  end

  defp resolve_credential(provider, entries, strategy, affinity_key, excluded) do
    with {:ok, selection} <-
           CredentialPool.select(provider.id, entries, strategy,
             affinity_key: affinity_key,
             exclude: excluded
           ),
         {:ok, credential} <- decrypt_credential(provider, selection.entry) do
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
          resolve_credential(
            provider,
            entries,
            strategy,
            affinity_key,
            [selection.credential_id | excluded]
          )

        {:error, {:chatgpt_refresh_transient, 429, _headers, _reason}} ->
          resolve_credential(
            provider,
            entries,
            strategy,
            affinity_key,
            [selection.credential_id | excluded]
          )

        {:error, {:chatgpt_refresh_transient, _status, _headers, _reason}} = error ->
          error

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Returns a runtime-safe connection config with one selected credential.

  The provider row may omit `base_url` and `transport` when the provider
  implementation has safe defaults. The returned map is the single shape used by
  provider dispatch, live-checks, and model catalog projections.
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
  def add_credential(provider_id, attrs) when is_binary(provider_id) and is_map(attrs) do
    result =
      Repo.transact(fn repo ->
        with %Provider{} = provider <- lock_provider(repo, provider_id),
             {:ok, pool, credential_id} <- append_credential(provider, attrs),
             {:ok, provider} <-
               provider
               |> Provider.changeset(%{credential_pool: pool})
               |> repo.update() do
          {:ok, {provider, credential_id}}
        else
          nil -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)

    case result do
      {:ok, {%Provider{} = provider, credential_id}} ->
        :ok = CredentialPool.mark_ok(provider.id, credential_id)
        {:ok, provider}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Replaces the supplied fields of one pool credential.

  Omitted credential fields are preserved. A credential id cannot change.
  """
  @spec update_credential(String.t(), String.t(), map()) :: provider_result()
  def update_credential(provider_id, credential_id, attrs)
      when is_binary(provider_id) and is_binary(credential_id) and is_map(attrs) do
    attrs = normalize_external_attrs(attrs)
    credential_replaced? = credential_replaced?(attrs)

    result =
      Repo.transact(fn repo ->
        with %Provider{} = provider <- lock_provider(repo, provider_id),
             {:ok, pool} <- replace_credential(provider, credential_id, attrs),
             {:ok, provider} <-
               provider
               |> Provider.changeset(%{credential_pool: pool})
               |> repo.update() do
          {:ok, provider}
        else
          nil -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)

    with {:ok, %Provider{} = provider} <- result do
      if credential_replaced? do
        :ok = CredentialPool.mark_ok(provider.id, credential_id)
      end

      result
    end
  end

  @doc """
  Deletes one credential from a provider pool.
  """
  @spec delete_credential(String.t(), String.t()) :: provider_result()
  def delete_credential(provider_id, credential_id)
      when is_binary(provider_id) and is_binary(credential_id) do
    result =
      Repo.transact(fn repo ->
        with %Provider{} = provider <- lock_provider(repo, provider_id),
             {:ok, pool} <- drop_credential(provider, credential_id),
             {:ok, provider} <-
               provider
               |> Provider.changeset(%{credential_pool: pool})
               |> repo.update() do
          {:ok, provider}
        else
          nil -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)

    with {:ok, %Provider{} = provider} <- result do
      :ok = CredentialPool.mark_dead(provider.id, credential_id, %{reason: "deleted"})
      result
    end
  end

  @doc """
  Changes the selection strategy without replacing credential entries.
  """
  @spec update_credential_strategy(String.t(), String.t()) :: provider_result()
  def update_credential_strategy(provider_id, strategy)
      when is_binary(provider_id) and is_binary(strategy) do
    Repo.transact(fn repo ->
      with true <- strategy in ~w(fill_first round_robin least_used random),
           %Provider{} = provider <- lock_provider(repo, provider_id),
           pool <- Map.put(credential_pool(provider), "strategy", strategy) do
        provider
        |> Provider.changeset(%{credential_pool: pool})
        |> repo.update()
      else
        false -> {:error, :invalid_credential_pool_strategy}
        nil -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Runs an atomic read-modify-write for one credential.

  The callback runs after the provider row is locked and receives the latest
  plaintext credential. It can return `{:ok, credential}` to replace the
  encrypted value, `{:ok, :unchanged}` to keep it, or an error tuple. This is
  used for rotating refresh tokens, where releasing the row lock between the
  upstream exchange and the database write could consume the same refresh
  token twice. The write does not clear derived health because a concurrent
  provider response can contain a newer quota observation.
  """
  @spec update_credential_under_lock(
          String.t(),
          String.t(),
          (Provider.t(), map() -> {:ok, map()} | {:ok, :unchanged} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def update_credential_under_lock(provider_id, credential_id, callback)
      when is_binary(provider_id) and is_binary(credential_id) and is_function(callback, 2) do
    result =
      Repo.transact(fn repo ->
        with %Provider{} = provider <- lock_provider(repo, provider_id),
             {:ok, entry} <- fetch_credential_entry(provider, credential_id),
             {:ok, credential} <- decrypt_credential(provider, entry) do
          case callback.(provider, credential) do
            {:ok, :unchanged} ->
              {:ok,
               %{
                 "provider" => provider,
                 "id" => credential_id,
                 "entry" => entry,
                 "credential" => credential
               }}

            {:ok, updated_credential} when is_map(updated_credential) ->
              with {:ok, ciphertext} <-
                     Crypto.seal(
                       updated_credential,
                       provider.id,
                       "credential:#{credential_id}"
                     ),
                   {:ok, provider} <-
                     persist_credential_ciphertext(
                       repo,
                       provider,
                       credential_id,
                       ciphertext
                     ),
                   {:ok, entry} <- fetch_credential_entry(provider, credential_id) do
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
      end)

    result
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

  # Write normalization happens before the changeset because credential sealing
  # depends on per-provider setting metadata.
  defp provider_attrs_for_write(attrs, %Provider{} = provider) do
    attrs = normalize_external_attrs(attrs)

    with :ok <- reject_credential_field(attrs),
         {:ok, attrs} <- reject_provider_id_change(attrs, provider),
         {:ok, attrs} <- normalize_connection_options(attrs, provider),
         {:ok, attrs} <- apply_credential_pool(attrs, provider) do
      {:ok, attrs}
    end
  end

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # A top-level singular credential would create a second execution path beside
  # the pool, so it is rejected.
  defp reject_credential_field(attrs) do
    case Map.has_key?(attrs, "credential") do
      true -> {:error, :credential_field_removed}
      false -> :ok
    end
  end

  defp reject_provider_id_change(attrs, %Provider{provider_id: nil}), do: {:ok, attrs}

  defp reject_provider_id_change(attrs, %Provider{provider_id: provider_id}) do
    case Map.get(attrs, "provider_id") do
      nil ->
        {:ok, attrs}

      value ->
        case normalize_id(value) do
          ^provider_id -> {:ok, Map.put(attrs, "provider_id", provider_id)}
          _value -> {:error, :provider_id_immutable}
        end
    end
  end

  defp apply_credential_pool(attrs, %Provider{id: row_id} = provider) when is_binary(row_id) do
    provider_kind = Map.get(attrs, "provider_kind") || provider_kind(provider)

    if Map.has_key?(attrs, "credential_pool") do
      with {:ok, credential_keys} <- credential_option_keys(provider_kind),
           {:ok, pool} <-
             normalize_and_seal_pool(
               Map.get(attrs, "credential_pool"),
               credential_pool(provider),
               row_id,
               credential_keys,
               provider_kind
             ) do
        {:ok, Map.put(attrs, "credential_pool", pool)}
      end
    else
      with {:ok, pool} <- default_credential_pool(provider_kind, provider, row_id) do
        {:ok, Map.put(attrs, "credential_pool", pool)}
      end
    end
  end

  defp apply_credential_pool(_attrs, _provider), do: {:error, :invalid_provider_id}

  defp normalize_connection_options(attrs, provider) do
    provider_kind = Map.get(attrs, "provider_kind") || provider_kind(provider)
    options = Map.get(attrs, "connection_options", connection_options(provider))

    with {:ok, normalized} <-
           Providers.normalize_connection_options(provider_kind, options || %{}) do
      {:ok, Map.put(attrs, "connection_options", normalized)}
    end
  end

  defp credential_option_keys(provider_kind) do
    with {:ok, definition} <- Providers.fetch(provider_kind) do
      {:ok, Providers.credential_option_keys(definition)}
    end
  end

  defp default_credential_pool(provider_kind, provider, row_id) do
    pool = credential_pool(provider)

    with [] <- Map.get(pool, "entries", []),
         {:ok, definition} <- Providers.fetch(provider_kind),
         false <- Providers.credential_required?(definition),
         credential_id <- Ankole.Ecto.UUIDv7.autogenerate(),
         {:ok, ciphertext} <- Crypto.seal(%{}, row_id, "credential:#{credential_id}") do
      {:ok,
       Map.put(pool, "entries", [
         %{
           "id" => credential_id,
           "label" => "Default",
           "priority" => 0,
           "source" => "provider_default",
           "disabled_at" => nil,
           "encrypted_credential" => ciphertext
         }
       ])}
    else
      [_entry | _entries] -> {:ok, pool}
      true -> {:ok, pool}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_and_seal_pool(pool, existing_pool, row_id, credential_keys, provider_kind)
       when is_map(pool) and is_list(credential_keys) do
    pool = normalize_external_attrs(pool)
    strategy = Map.get(pool, "strategy", Map.get(existing_pool, "strategy", "fill_first"))
    entries = Map.get(pool, "entries", [])

    with true <- strategy in ~w(fill_first round_robin least_used random),
         true <- is_list(entries),
         {:ok, entries} <-
           seal_credential_entries(
             entries,
             Map.get(existing_pool, "entries", []),
             row_id,
             credential_keys,
             provider_kind
           ) do
      {:ok, %{"strategy" => strategy, "entries" => entries}}
    else
      false -> {:error, :invalid_credential_pool}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_and_seal_pool(
         _pool,
         _existing_pool,
         _row_id,
         _credential_keys,
         _provider_kind
       ),
       do: {:error, :invalid_credential_pool}

  defp append_credential(%Provider{} = provider, attrs) do
    pool = credential_pool(provider)
    entries = Map.get(pool, "entries", [])
    attrs = normalize_external_attrs(attrs)

    with {:ok, credential_keys} <- credential_option_keys(provider.provider_kind),
         id <- normalized_credential_id(Map.get(attrs, "id")),
         false <- Enum.any?(entries, &(Map.get(&1, "id") == id)),
         {:ok, entry} <-
           seal_credential_entry(
             Map.put(attrs, "id", id),
             nil,
             provider.id,
             id,
             credential_keys,
             provider.provider_kind,
             credential_replaced?(attrs)
           ) do
      {:ok, Map.put(pool, "entries", entries ++ [entry]), id}
    else
      true -> {:error, :duplicate_credential_id}
      {:error, _reason} = error -> error
    end
  end

  defp replace_credential(%Provider{} = provider, credential_id, attrs) do
    attrs = normalize_external_attrs(attrs)
    credential_replaced? = credential_replaced?(attrs)

    with false <-
           Map.has_key?(attrs, "id") and
             normalized_credential_id(Map.get(attrs, "id")) != credential_id,
         {:ok, existing} <- fetch_credential_entry(provider, credential_id),
         {:ok, credential_keys} <- credential_option_keys(provider.provider_kind),
         {:ok, credential} <-
           credential_for_replace(provider, existing, attrs, credential_keys),
         entry_attrs <-
           existing
           |> Map.take(~w(id label priority disabled_at source))
           |> maybe_clear_invalid_disabled_at(existing, attrs)
           |> Map.merge(credential)
           |> Map.merge(Map.delete(attrs, "id"))
           |> Map.put("id", credential_id),
         {:ok, entry} <-
           seal_credential_entry(
             entry_attrs,
             existing,
             provider.id,
             credential_id,
             credential_keys,
             provider.provider_kind,
             credential_replaced?
           ) do
      {:ok, replace_pool_entry(credential_pool(provider), credential_id, entry)}
    else
      true -> {:error, :credential_id_immutable}
      {:error, _reason} = error -> error
    end
  end

  defp credential_for_replace(provider, existing, attrs, credential_keys) do
    case decrypt_credential(provider, existing) do
      {:ok, credential} ->
        {:ok, credential}

      {:error, _reason} = error ->
        if Enum.any?(credential_keys, &Map.has_key?(attrs, &1)) do
          {:ok, %{}}
        else
          error
        end
    end
  end

  defp maybe_clear_invalid_disabled_at(base, %{"reauth_required" => true}, attrs) do
    if Map.has_key?(attrs, "disabled_at"), do: base, else: Map.put(base, "disabled_at", nil)
  end

  defp maybe_clear_invalid_disabled_at(base, _existing, _attrs), do: base

  defp drop_credential(%Provider{} = provider, credential_id) do
    pool = credential_pool(provider)
    entries = Map.get(pool, "entries", [])

    case Enum.split_with(entries, &(Map.get(&1, "id") == credential_id)) do
      {[], _rest} -> {:error, :credential_not_found}
      {[_entry], rest} -> {:ok, Map.put(pool, "entries", rest)}
    end
  end

  defp fetch_credential_entry(%Provider{} = provider, credential_id) do
    provider
    |> credential_pool()
    |> Map.get("entries", [])
    |> Enum.find(&(Map.get(&1, "id") == credential_id))
    |> case do
      %{} = entry -> {:ok, entry}
      nil -> {:error, :credential_not_found}
    end
  end

  defp persist_credential_ciphertext(repo, provider, credential_id, ciphertext) do
    with {:ok, entry} <- fetch_credential_entry(provider, credential_id) do
      updated = Map.put(entry, "encrypted_credential", ciphertext)
      pool = replace_pool_entry(credential_pool(provider), credential_id, updated)

      provider
      |> Provider.changeset(%{credential_pool: pool})
      |> repo.update()
    end
  end

  defp replace_pool_entry(pool, credential_id, replacement) do
    Map.update!(pool, "entries", fn entries ->
      Enum.map(entries, fn
        %{"id" => ^credential_id} -> replacement
        entry -> entry
      end)
    end)
  end

  defp clear_pool_health(%Provider{} = provider) do
    provider
    |> credential_pool()
    |> Map.get("entries", [])
    |> Enum.each(fn entry ->
      CredentialPool.mark_ok(provider.id, Map.fetch!(entry, "id"))
    end)
  end

  defp seal_credential_entries(
         entries,
         existing_entries,
         row_id,
         credential_keys,
         provider_kind
       ) do
    existing_by_id = Map.new(existing_entries, &{Map.get(&1, "id"), &1})

    entries
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw_entry, {:ok, acc, seen} ->
      with true <- is_map(raw_entry),
           entry <- normalize_external_attrs(raw_entry),
           id <- normalized_credential_id(Map.get(entry, "id")),
           false <- MapSet.member?(seen, id),
           {:ok, stored_entry} <-
             seal_credential_entry(
               entry,
               Map.get(existing_by_id, id),
               row_id,
               id,
               credential_keys,
               provider_kind,
               credential_replaced?(entry)
             ) do
        {:cont, {:ok, [stored_entry | acc], MapSet.put(seen, id)}}
      else
        false -> {:halt, {:error, :invalid_credential_entry}}
        true -> {:halt, {:error, :duplicate_credential_id}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _seen} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp seal_credential_entry(
         entry,
         existing,
         row_id,
         id,
         credential_keys,
         provider_kind,
         credential_replaced?
       ) do
    allowed =
      MapSet.new(
        ~w(id label priority disabled_at source reauth_required migration_error) ++
          credential_keys
      )

    unknown_keys =
      entry
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))

    credential =
      entry
      |> Map.take(credential_keys)
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    with [] <- unknown_keys,
         {:ok, credential} <- normalize_credential_for_seal(provider_kind, credential),
         {:ok, ciphertext} <-
           credential_ciphertext(credential, existing, row_id, id),
         {:ok, label} <- normalize_credential_label(Map.get(entry, "label"), existing, id),
         {:ok, priority} <- normalize_credential_priority(Map.get(entry, "priority"), existing),
         {:ok, source} <- normalize_credential_source(Map.get(entry, "source"), existing),
         {:ok, disabled_at} <-
           normalize_disabled_at(Map.get(entry, "disabled_at"), entry, existing) do
      stored =
        %{
          "id" => id,
          "label" => label,
          "priority" => priority,
          "source" => source,
          "disabled_at" => disabled_at,
          "encrypted_credential" => ciphertext
        }
        |> maybe_preserve_reauth_metadata(entry, existing, credential_replaced?)

      {:ok, stored}
    else
      [_key | _keys] -> {:error, {:credential_entry_unknown_keys, Enum.sort(unknown_keys)}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_credential_for_seal(_provider_kind, credential)
       when map_size(credential) == 0,
       do: {:ok, credential}

  defp normalize_credential_for_seal(provider_kind, credential),
    do: Providers.normalize_credential_options(provider_kind, credential)

  defp credential_ciphertext(credential, _existing, row_id, id) when map_size(credential) > 0 do
    Crypto.seal(credential, row_id, "credential:#{id}")
  end

  defp credential_ciphertext(_credential, %{"encrypted_credential" => ciphertext}, _row_id, _id)
       when is_binary(ciphertext),
       do: {:ok, ciphertext}

  defp credential_ciphertext(_credential, %{"reauth_required" => true}, _row_id, _id),
    do: {:ok, nil}

  defp credential_ciphertext(_credential, _existing, _row_id, _id),
    do: {:error, :credential_fields_required}

  defp normalized_credential_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> Ankole.Ecto.UUIDv7.autogenerate()
      id -> id
    end
  end

  defp normalized_credential_id(_value), do: Ankole.Ecto.UUIDv7.autogenerate()

  defp normalize_credential_label(value, _existing, _id)
       when is_binary(value) and value != "",
       do: {:ok, String.trim(value)}

  defp normalize_credential_label(_value, %{"label" => label}, _id) when is_binary(label),
    do: {:ok, label}

  defp normalize_credential_label(_value, _existing, id), do: {:ok, id}

  defp normalize_credential_priority(value, _existing) when is_integer(value), do: {:ok, value}

  defp normalize_credential_priority(_value, %{"priority" => value}) when is_integer(value),
    do: {:ok, value}

  defp normalize_credential_priority(_value, _existing), do: {:ok, 0}

  defp normalize_credential_source(value, _existing)
       when is_binary(value) and value != "",
       do: {:ok, String.trim(value)}

  defp normalize_credential_source(_value, %{"source" => source})
       when is_binary(source) and source != "",
       do: {:ok, source}

  defp normalize_credential_source(_value, _existing), do: {:ok, "manual"}

  defp maybe_preserve_reauth_metadata(stored, entry, existing, credential_replaced?) do
    reauth_required =
      Map.get(entry, "reauth_required", Map.get(existing || %{}, "reauth_required"))

    if reauth_required == true and not credential_replaced? do
      stored
      |> Map.put("reauth_required", true)
      |> maybe_put_text(
        "migration_error",
        Map.get(entry, "migration_error", Map.get(existing || %{}, "migration_error"))
      )
    else
      stored
    end
  end

  defp credential_replaced?(entry) do
    Enum.any?(entry, fn
      {key, value} ->
        key not in ~w(id label priority disabled_at source reauth_required migration_error) and
          value not in [nil, ""]
    end)
  end

  defp maybe_put_text(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put_text(map, _key, _value), do: map

  defp normalize_disabled_at(value, entry, _existing)
       when is_binary(value) and is_map_key(entry, "disabled_at") do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _error -> {:error, :invalid_credential_disabled_at}
    end
  end

  defp normalize_disabled_at(nil, entry, _existing) when is_map_key(entry, "disabled_at"),
    do: {:ok, nil}

  defp normalize_disabled_at(_value, _entry, %{"disabled_at" => value}), do: {:ok, value}
  defp normalize_disabled_at(_value, _entry, _existing), do: {:ok, nil}

  defp runtime_base_url(%Provider{base_url: base_url}, _provider_kind)
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, %{base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, _provider_kind), do: {:error, :missing_base_url}

  defp lock_provider(repo, provider_id) do
    Provider
    |> where([provider], provider.provider_id == ^normalize_id(provider_id))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Finds every agent model profile still pointing at this provider, returned as
  # "agent_uid:profile" labels. A non-empty list blocks the disable so an
  # operator cannot silently break agents that depend on the provider; profiles
  # live inside each agent's `options` JSON, so the database filters and expands
  # only matching JSONB profile entries.
  defp provider_references(repo, provider_id) do
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

    Enum.map(rows, fn [reference] -> reference end)
  end

  defp provider_kind(%Provider{provider_kind: provider_kind}), do: provider_kind
  defp provider_kind(_provider), do: nil

  defp connection_options(%Provider{connection_options: options}) when is_map(options),
    do: options

  defp connection_options(_provider), do: %{}

  defp credential_pool(%Provider{credential_pool: pool}) when is_map(pool) do
    %{
      "strategy" => Map.get(pool, "strategy", "fill_first"),
      "entries" => Map.get(pool, "entries", [])
    }
  end

  defp credential_pool(_provider), do: %{"strategy" => "fill_first", "entries" => []}

  defp decrypt_credential(%Provider{id: row_id}, %{
         "id" => credential_id,
         "encrypted_credential" => ciphertext
       })
       when is_binary(row_id) and is_binary(credential_id) and is_binary(ciphertext) do
    case Crypto.unseal(ciphertext, row_id, "credential:#{credential_id}") do
      {:ok, %{} = credential} ->
        {:ok, credential}

      {:ok, _value} ->
        {:error, {:invalid_credential_payload, credential_id}}

      {:error, reason} ->
        {:error, {:credential_decrypt_failed, credential_id, reason}}
    end
  end

  defp decrypt_credential(_provider, entry),
    do: {:error, {:invalid_credential_entry, Map.get(entry, "id")}}

  # API projections expose pool metadata, selected health, and a small set of
  # account facts. Token and API-key fields never leave this module.
  defp credential_pool_projection(%Provider{} = provider) do
    pool = credential_pool(provider)
    entries = Map.get(pool, "entries", [])
    statuses = CredentialPool.statuses(provider.id, entries)

    %{
      "strategy" => Map.get(pool, "strategy", "fill_first"),
      "entries" =>
        Enum.map(entries, fn entry ->
          credential_id = Map.get(entry, "id")
          status = Map.get(statuses, credential_id, %{"status" => "dead"})

          account_projection =
            case decrypt_credential(provider, entry) do
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
          |> Map.merge(projected_status(entry, status))
        end)
    }
  end

  defp projected_status(%{"reauth_required" => true}, _status),
    do: %{"status" => "dead", "reauth_required" => true}

  defp projected_status(_entry, status), do: status

  defp context_value(ctx, key) when is_list(ctx), do: Keyword.get(ctx, key)

  defp context_value(ctx, key) when is_map(ctx) do
    Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key))
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
          "capability_specs",
          "settings"
        ])

      {:error, _reason} ->
        %{}
    end
  end

  defp normalize_id(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_id(value), do: value
end
