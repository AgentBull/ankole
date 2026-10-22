defmodule Ankole.AIGateway.ProviderConfigs.Credentials do
  @moduledoc "Owns encrypted credential-pool values and their revision semantics."

  alias Ankole.Attrs
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.ProviderConfigs.{Crypto, Provider}

  # The resource action supplies its declared identity before credential sealing.
  def provider_attrs_for_write(attrs, %Provider{} = provider) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with :ok <- reject_credential_field(attrs),
         {:ok, attrs} <- reject_provider_id_change(attrs, provider),
         {:ok, attrs} <- normalize_connection_options(attrs, provider),
         {:ok, attrs} <- apply_credential_pool(attrs, provider) do
      {:ok, attrs}
    end
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
        case Provider.normalize_id(value) do
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
           "health_revision" => health_revision(),
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
    pool = Attrs.normalize_external_attrs(pool)
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

  def append_credential(%Provider{} = provider, attrs) do
    pool = credential_pool(provider)
    entries = Map.get(pool, "entries", [])
    attrs = Attrs.normalize_external_attrs(attrs)

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

  def replace_credential(%Provider{} = provider, credential_id, attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)
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

  def drop_credential(%Provider{} = provider, credential_id) do
    pool = credential_pool(provider)
    entries = Map.get(pool, "entries", [])

    case Enum.split_with(entries, &(Map.get(&1, "id") == credential_id)) do
      {[], _rest} -> {:error, :credential_not_found}
      {[_entry], rest} -> {:ok, Map.put(pool, "entries", rest)}
    end
  end

  def fetch_credential_entry(%Provider{} = provider, credential_id) do
    provider
    |> credential_pool()
    |> Map.get("entries", [])
    |> Enum.find(&(Map.get(&1, "id") == credential_id))
    |> case do
      %{} = entry -> {:ok, entry}
      nil -> {:error, :credential_not_found}
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
           entry <- Attrs.normalize_external_attrs(raw_entry),
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
          "health_revision" => health_revision(existing, credential_replaced?),
          "encrypted_credential" => ciphertext
        }
        |> maybe_preserve_reauth_metadata(entry, existing, credential_replaced?)
        |> preserve_cooldown(existing)

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

  defp preserve_cooldown(stored, existing) do
    if existing && stored["health_revision"] == existing["health_revision"],
      do: Map.merge(stored, Map.take(existing, ~w(cooldown_until cooldown_reason))),
      else: stored
  end

  defp credential_replaced?(entry) do
    Enum.any?(entry, fn
      {key, value} ->
        key not in ~w(id label priority disabled_at source reauth_required migration_error) and
          value not in [nil, ""]
    end)
  end

  def rotate_health_revisions(pool) do
    Map.update!(pool, "entries", fn entries ->
      Enum.map(
        entries,
        &(&1
          |> Map.put("health_revision", health_revision())
          |> Map.drop(~w(cooldown_until cooldown_reason)))
      )
    end)
  end

  defp health_revision(_existing, true), do: health_revision()

  defp health_revision(%{"health_revision" => revision}, false)
       when is_binary(revision) and revision != "",
       do: revision

  defp health_revision(nil, false), do: health_revision()

  defp health_revision, do: Ankole.Ecto.UUIDv7.autogenerate()

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

  defp provider_kind(%Provider{provider_kind: provider_kind}), do: provider_kind
  defp provider_kind(_provider), do: nil

  defp connection_options(%Provider{connection_options: options}) when is_map(options),
    do: options

  defp connection_options(_provider), do: %{}

  def credential_pool(%Provider{credential_pool: pool}) when is_map(pool) do
    %{
      "strategy" => Map.get(pool, "strategy", "fill_first"),
      "entries" => Map.get(pool, "entries", [])
    }
  end

  def credential_pool(_provider), do: %{"strategy" => "fill_first", "entries" => []}

  def decrypt_credential(%Provider{id: row_id}, %{
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

  def decrypt_credential(_provider, entry),
    do: {:error, {:invalid_credential_entry, Map.get(entry, "id")}}

  def refresh_credential(provider, credential_id, credential) do
    with {:ok, entry} <- fetch_credential_entry(provider, credential_id),
         {:ok, ciphertext} <- Crypto.seal(credential, provider.id, "credential:#{credential_id}") do
      updated = Map.put(entry, "encrypted_credential", ciphertext)
      {:ok, replace_pool_entry(credential_pool(provider), credential_id, updated)}
    end
  end

  def select_strategy(provider, strategy) do
    if strategy in ~w(fill_first round_robin least_used random),
      do: {:ok, Map.put(credential_pool(provider), "strategy", strategy)},
      else: {:error, :invalid_credential_pool_strategy}
  end

  def cooldown(provider, credential, until, reason) do
    with {:ok, current} <- fetch_credential_entry(provider, credential["id"]),
         true <- current["health_revision"] == credential["health_revision"] do
      previous = cooldown_deadline(current)

      if previous && DateTime.compare(previous, until) != :lt do
        {:ok, :unchanged}
      else
        updated =
          current
          |> Map.put("cooldown_until", DateTime.to_iso8601(until))
          |> Map.put("cooldown_reason", reason)

        {:ok, replace_pool_entry(credential_pool(provider), credential["id"], updated)}
      end
    else
      false -> {:ok, :unchanged}
      {:error, :credential_not_found} -> {:ok, :unchanged}
    end
  end

  defp cooldown_deadline(%{"cooldown_until" => value}) when is_binary(value),
    do: Ankole.Attrs.parse_datetime(value)

  defp cooldown_deadline(_entry), do: nil
end
