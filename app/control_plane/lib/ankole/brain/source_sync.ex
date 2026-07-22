defmodule Ankole.Brain.SourceSync do
  @moduledoc "Mechanical synchronization of connector documents into shared read-only entries."

  import Ecto.Query, warn: false

  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.MarkdownChunker
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.RetainedSource
  alias Ankole.Brain.SourceConnectors
  alias Ankole.Brain.SourceWithdrawal
  alias Ankole.Repo

  @media_type "text/markdown; charset=utf-8"

  @spec register(String.t(), String.t(), keyword()) ::
          {:ok, RetainedSource.t()} | {:error, term()}
  def register(connector_id, locator, opts \\ [])

  def register(connector_id, locator, opts)
      when is_binary(connector_id) and is_binary(locator) and is_list(opts) do
    with {:ok, connector_id} <- nonblank(connector_id, :connector_id),
         {:ok, locator} <- nonblank(locator, :locator),
         {:ok, connector} <- SourceConnectors.fetch(connector_id, opts),
         reference = reference(connector_id, locator),
         :ok <- ensure_available(connector, reference),
         {:ok, revision} <- connector_revision(connector, reference),
         {:ok, exported} <- connector_export(connector, reference),
         {:ok, config} <- Config.sources() do
      persist_registration(connector_id, locator, revision, exported, config, opts)
    end
  end

  def register(_connector_id, _locator, _opts), do: {:error, :invalid_source_registration}

  @spec sync(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync(source_id, opts \\ [])

  def sync(source_id, opts) when is_list(opts) do
    with {:ok, source_id} <- cast_uuid(source_id),
         %RetainedSource{} = source <- Repo.get(RetainedSource, source_id),
         true <- source.capture_method != "file",
         {:ok, connector} <- SourceConnectors.fetch(source.connector_id, opts) do
      sync_source(source, connector)
    else
      nil -> {:error, :source_not_found}
      false -> {:error, :source_is_not_connector_managed}
      {:error, _reason} = error -> error
    end
  end

  def sync(_source_id, _opts), do: {:error, :invalid_source_sync}

  defp sync_source(source, connector) do
    reference = reference(source.connector_id, source.origin_locator)

    case availability(connector, reference) do
      {:ok, :available} -> sync_available(source, connector, reference)
      {:ok, state} when state in [:deleted, :access_lost] -> withdraw(source, state)
      {:error, reason} -> mark_failed(source, reason)
    end
  end

  defp sync_available(source, connector, reference) do
    with {:ok, revision} <- connector_revision(connector, reference) do
      if revision == source.revision and source.sync_state == :current do
        touch(source, :unchanged_revision)
      else
        with {:ok, exported} <- connector_export(connector, reference),
             {:ok, config} <- Config.sources() do
          persist_export(source, revision, exported, config)
        end
      end
    else
      {:error, reason} -> mark_failed(source, reason)
    end
  end

  defp persist_registration(connector_id, locator, revision, exported, config, opts) do
    now = DateTime.utc_now(:microsecond)
    content = exported.markdown
    id = Ankole.Ecto.UUIDv7.autogenerate()

    attrs = %{
      id: id,
      document_id: "brain-source:#{id}",
      owner_uid: Scope.shared_owner_uid(),
      store_key: "shared",
      capture_method: connector_id,
      connector_id: connector_id,
      revision: revision,
      title: exported.title,
      origin_locator: locator,
      source_url: exported.url,
      media_type: @media_type,
      byte_size: byte_size(content),
      sha256: sha256(content),
      raw_content: content,
      captured_by_uid: Keyword.get(opts, :captured_by_uid),
      sync_state: :current,
      last_synced_at: now
    }

    Repo.transact(fn repo ->
      with {:ok, source} <-
             repo.insert(RetainedSource.changeset(%RetainedSource{id: id}, attrs)),
           {:ok, _entry_id} <- replace_mirror(repo, source, exported, config) do
        {:ok, source}
      end
    end)
  end

  defp persist_export(source, revision, exported, config) do
    now = DateTime.utc_now(:microsecond)
    digest = sha256(exported.markdown)

    Repo.transact(fn repo ->
      unchanged_content? = digest == source.sha256

      with {:ok, source} <-
             update_source(repo, source, revision, exported, digest, now),
           {:ok, entry_id} <-
             update_mirror(repo, source, exported, config, unchanged_content?) do
        {:ok,
         %{
           status: if(unchanged_content?, do: :metadata_updated, else: :replaced),
           source_id: source.id,
           entry_id: entry_id,
           revision: revision
         }}
      end
    end)
  end

  defp update_source(repo, source, revision, exported, digest, now) do
    source
    |> RetainedSource.changeset(%{
      revision: revision,
      title: exported.title,
      source_url: exported.url,
      media_type: @media_type,
      byte_size: byte_size(exported.markdown),
      sha256: digest,
      raw_content: exported.markdown,
      sync_state: :current,
      last_synced_at: now
    })
    |> update_if_current(repo)
  end

  defp update_mirror(repo, source, exported, config, unchanged_content?) do
    case mirror_entry(repo, source.document_id) do
      %Entry{} = entry when unchanged_content? ->
        refresh_mirror_metadata(repo, source, entry, exported)

      _entry_or_missing ->
        replace_mirror(repo, source, exported, config)
    end
  end

  defp refresh_mirror_metadata(repo, source, entry, exported) do
    name = available_name(repo, exported.title, source, entry.id)

    operations =
      [
        field_operation("set_name", entry, :name, name),
        property_operation(entry, "source_revision", source.revision),
        property_operation(entry, "source_url", exported.url)
      ]
      |> Enum.reject(&is_nil/1)

    case operations do
      [] ->
        {:ok, entry.id}

      operations ->
        with {:ok, _result} <- write(repo, operations, source.document_id), do: {:ok, entry.id}
    end
  end

  defp replace_mirror(repo, source, exported, config) do
    with :ok <- delete_existing_mirror(repo, source.document_id),
         {:ok, chunks} <- mirror_chunks(exported.markdown, source.document_id, config),
         name <- available_name(repo, exported.title, source),
         [first | rest] <- chunks,
         {:ok, created} <-
           write(
             repo,
             %{
               operation: "create_entry",
               name: name,
               type: "external_document",
               summary: "",
               properties: mirror_properties(source, exported),
               initial_body: first
             },
             source.document_id
           ),
         [%{entry_id: entry_id, entry_lock_version: lock_version} | _] <- created.results,
         :ok <- append_chunks(repo, entry_id, lock_version, rest, source.document_id) do
      {:ok, entry_id}
    else
      [] -> {:error, :empty_source_document}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_source_mirror_result}
    end
  end

  defp delete_existing_mirror(repo, document_id) do
    case mirror_entry(repo, document_id) do
      nil ->
        :ok

      %Entry{} = entry ->
        with {:ok, _result} <-
               write(
                 repo,
                 %{
                   operation: "delete_entry",
                   entry_id: entry.id,
                   expected_entry_lock_version: entry.lock_version
                 },
                 document_id
               ),
             do: :ok
    end
  end

  defp append_chunks(_repo, _entry_id, _lock_version, [], _document_id), do: :ok

  defp append_chunks(repo, entry_id, lock_version, chunks, document_id) do
    operations =
      Enum.map(chunks, fn body ->
        %{
          operation: "append_block",
          entry_id: entry_id,
          expected_entry_lock_version: lock_version,
          body: body
        }
      end)

    with {:ok, _result} <- write(repo, operations, document_id), do: :ok
  end

  defp mirror_chunks(markdown, document_id, config) do
    marker = "Source: src:#{document_id}"
    marker_tokens = Ankole.Kernel.estimate_o200k_base_tokens(marker) + 2
    content_limit = max(config["block_max_tokens"] - marker_tokens, 1)

    with {:ok, chunks} <- MarkdownChunker.split(markdown, content_limit) do
      {:ok, Enum.map(chunks, &(&1 <> "\n\n" <> marker))}
    end
  end

  defp write(repo, operations, document_id) do
    with {:ok, scope} <- Scope.for_store(Scope.shared_owner_uid(), "shared") do
      Knowledge.apply_operations(
        scope,
        operations,
        %{kind: :dreaming, uid: Scope.shared_owner_uid()},
        repo: repo,
        metadata: %{"surface" => "source_sync"},
        write_context: {:dreaming, [document_id]}
      )
    end
  end

  defp mirror_entry(repo, document_id) do
    repo.one(
      from entry in Entry,
        where: entry.owner_uid == ^Scope.shared_owner_uid() and entry.store_key == "shared",
        where: fragment("?->>'source_document_id' = ?", entry.properties, ^document_id),
        where: fragment("?->>'source_mirror' = 'true'", entry.properties),
        limit: 1
    )
  end

  defp available_name(repo, title, source, except_id \\ nil) do
    query =
      from entry in Entry,
        where: entry.owner_uid == ^Scope.shared_owner_uid() and entry.store_key == "shared",
        where: entry.name == ^title

    query = if except_id, do: where(query, [entry], entry.id != ^except_id), else: query
    occupied? = repo.exists?(query)

    if occupied? do
      suffix = source.origin_locator |> sha256() |> String.slice(0, 8)
      "#{title} (#{source.connector_id}-#{suffix})"
    else
      title
    end
  end

  defp mirror_properties(source, exported) do
    %{
      "source_mirror" => true,
      "source_document_id" => source.document_id,
      "source_type" => source.connector_id,
      "source_locator" => source.origin_locator,
      "source_revision" => source.revision,
      "source_url" => exported.url
    }
  end

  defp field_operation(_operation, _entry, _field, nil), do: nil

  defp field_operation(operation, entry, field, value) do
    current = Map.fetch!(entry, field)

    if current == value do
      nil
    else
      %{
        field => value,
        operation: operation,
        entry_id: entry.id,
        expected_entry_lock_version: entry.lock_version
      }
    end
  end

  defp property_operation(entry, key, value) do
    if Map.get(entry.properties || %{}, key) == value do
      nil
    else
      %{
        operation: "set_property",
        entry_id: entry.id,
        expected_entry_lock_version: entry.lock_version,
        key: key,
        value: value
      }
    end
  end

  defp withdraw(source, state) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with {:ok, source} <-
             update_sync_state(repo, source, %{sync_state: state, last_synced_at: now}),
           {:ok, result} <- SourceWithdrawal.withdraw(source.document_id, [], repo: repo) do
        {:ok, %{status: state, source_id: source.id, withdrawal: result}}
      end
    end)
  end

  defp mark_failed(source, reason) do
    now = DateTime.utc_now(:microsecond)

    case update_sync_state(Repo, source, %{sync_state: :failed, last_synced_at: now}) do
      {:ok, _source} -> {:error, {:source_sync_failed, reason}}
      {:error, :source_sync_conflict} = error -> error
      {:error, changeset} -> {:error, {:source_sync_state_failed, changeset}}
    end
  end

  defp touch(source, status) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _source} <-
           update_sync_state(Repo, source, %{
             sync_state: source.sync_state,
             last_synced_at: now
           }) do
      {:ok, %{status: status, source_id: source.id, revision: source.revision}}
    end
  end

  defp update_sync_state(repo, source, attrs) do
    source
    |> RetainedSource.sync_state_changeset(attrs)
    |> update_if_current(repo)
  end

  defp update_if_current(changeset, repo) do
    case repo.update(changeset,
           stale_error_field: :lock_version,
           stale_error_message: "source changed during synchronization"
         ) do
      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :lock_version),
          do: {:error, :source_sync_conflict},
          else: error

      result ->
        result
    end
  end

  defp availability(connector, reference) do
    case connector.availability(reference) do
      {:ok, value} when value in [:available, :deleted, :access_lost] -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_source_availability, value}}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_source_availability_result, value}}
    end
  rescue
    exception -> {:error, {:source_connector_exception, Exception.message(exception)}}
  end

  defp ensure_available(connector, reference) do
    case availability(connector, reference) do
      {:ok, :available} -> :ok
      {:ok, state} -> {:error, {:source_unavailable, state}}
      {:error, _reason} = error -> error
    end
  end

  defp connector_revision(connector, reference) do
    case connector.revision(reference) do
      {:ok, revision} -> nonblank(revision, :revision)
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_source_revision_result, value}}
    end
  rescue
    exception -> {:error, {:source_connector_exception, Exception.message(exception)}}
  end

  defp connector_export(connector, reference) do
    case connector.export(reference) do
      {:ok, exported} when is_map(exported) -> normalize_export(exported)
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_source_export_result, value}}
    end
  rescue
    exception -> {:error, {:source_connector_exception, Exception.message(exception)}}
  end

  defp normalize_export(exported) do
    with {:ok, title} <- exported |> value(:title) |> nonblank(:title),
         {:ok, markdown} <- exported |> value(:markdown) |> nonblank(:markdown),
         {:ok, url} <- optional_text(value(exported, :url), :url) do
      {:ok, %{title: title, markdown: markdown, url: url}}
    end
  end

  defp reference(connector_id, locator), do: %{connector_id: connector_id, locator: locator}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_source_id}
    end
  end

  defp nonblank(value, _field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :blank_source_connector_value}
      value -> {:ok, value}
    end
  end

  defp nonblank(_value, field), do: {:error, {:invalid_source_connector_field, field}}

  defp optional_text(nil, _field), do: {:ok, nil}
  defp optional_text(value, field), do: nonblank(value, field)

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
