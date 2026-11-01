defmodule Ankole.Files.Objects do
  @moduledoc "Streams immutable tenant objects and completes them with their durable references."

  require Ash.Query

  alias Ankole.Files.Schemas.FileObject
  alias Ankole.{Files, ObjectStore, Repo}

  @chunk_bytes 1024 * 1024
  @collection_batch 100

  def upload_limit, do: ObjectStore.write_limit()

  def store({:file, path} = content) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} ->
        with :ok <- check_size(size), do: do_store(content)

      {:ok, _} ->
        {:error, {:invalid_source, :not_regular_file}}

      {:error, reason} ->
        {:error, {:invalid_source, reason}}
    end
  rescue
    error in File.Error -> {:error, {:invalid_source, error.reason}}
  end

  def store(content) when is_binary(content) do
    with :ok <- check_size(byte_size(content)), do: do_store(content)
  end

  def store(content), do: do_store(content)

  defp check_size(size) do
    with {:ok, limit} <- upload_limit() do
      if size <= limit, do: :ok, else: {:error, {:file_too_large, size, limit}}
    end
  end

  defp do_store(content) do
    Repo.assert_outside_transaction!()
    id = Ankole.Ecto.UUIDv7.autogenerate()

    with {:ok, object} <-
           Ankole.Ash.create(FileObject, :create_in_tx, %{
             id: id,
             storage_key: "tenants/#{Repo.tenant_id!()}/objects/#{id}",
             created_at: DateTime.utc_now(:microsecond)
           }),
         {:ok, written} <- ObjectStore.write_stream(object.storage_key, source(content)) do
      {:ok, Map.put(written, :object_id, object.id)}
    end
  end

  defp source({:file, path}), do: File.stream!(path, @chunk_bytes)
  defp source(bytes) when is_binary(bytes), do: [bytes]
  defp source(stream), do: stream

  def fetch(id) when is_binary(id) do
    FileObject
    |> Ash.Query.filter(id == ^id and not is_nil(completed_at))
    |> Ankole.Ash.read_one()
    |> found()
  end

  def fetch(_id), do: {:error, :not_found}

  def complete_in_tx(stored) when is_map(stored) do
    require_transaction!(:complete_in_tx)
    id = Ankole.Attrs.get(stored, :object_id)

    with {:ok, digest} <- digest(Ankole.Attrs.get(stored, :sha256)),
         size when is_integer(size) and size >= 0 <- Ankole.Attrs.get(stored, :size),
         {:ok, object} <- lock(id) do
      complete(object, digest, size)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_object}
    end
  end

  def complete_in_tx(id) when is_binary(id) do
    require_transaction!(:complete_in_tx)
    fetch(id)
  end

  defp complete(%{completed_at: nil} = object, digest, size) do
    Ankole.Ash.update(object, :complete_in_tx, %{
      sha256: digest,
      size: size,
      completed_at: DateTime.utc_now(:microsecond)
    })
  end

  defp complete(%{sha256: digest, size: size} = object, digest, size), do: {:ok, object}
  defp complete(_object, _digest, _size), do: {:error, :object_content_mismatch}

  defp lock(id) do
    FileObject
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ankole.Ash.read_one(lock_identity: {"file_objects", [id]})
    |> found()
  end

  def read(id) do
    with {:ok, object} <- fetch(id), do: object_result(ObjectStore.read(object.storage_key))
  end

  def read_to_file(id, path) do
    with {:ok, object} <- fetch(id),
         do: object_result(ObjectStore.read_to_file(object.storage_key, path))
  end

  def read_range(%FileObject{storage_key: key, size: size}, offset, length) do
    case min(length, max(size - offset, 0)) do
      0 -> {:ok, <<>>}
      count -> object_result(ObjectStore.read_range(key, offset, count))
    end
  end

  def read_range(id, offset, length) do
    with {:ok, object} <- fetch(id),
         do: read_range(object, offset, length)
  end

  def collect do
    cutoff = DateTime.add(DateTime.utc_now(:microsecond), -24, :hour)
    collect_after(cutoff, nil, 0)
  end

  def enqueue_tenant_object_deletions_in_tx do
    require_transaction!(:enqueue_tenant_object_deletions_in_tx)
    enqueue_tenant_objects(nil)
  end

  defp enqueue_tenant_objects(after_id) do
    query = FileObject |> Ash.Query.sort(id: :asc) |> Ash.Query.limit(@collection_batch)
    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query
    objects = Ankole.Ash.read!(query)

    with :ok <-
           Enum.reduce_while(objects, :ok, fn object, :ok ->
             case Oban.insert(Files.Jobs.DeleteObject.new(%{"storage_key" => object.storage_key})) do
               {:ok, _} -> {:cont, :ok}
               error -> {:halt, error}
             end
           end) do
      case List.last(objects) do
        nil -> :ok
        object -> enqueue_tenant_objects(object.id)
      end
    end
  end

  defp collect_after(cutoff, after_id, count) do
    case unreferenced_ids(cutoff, after_id) do
      [] ->
        {:ok, count}

      ids ->
        removed = Enum.count(ids, &collect_one/1)
        collect_after(cutoff, List.last(ids), count + removed)
    end
  end

  # These rows are candidates. The foreign keys make the final delete fail if
  # another transaction has attached a reference since this query ran.
  defp unreferenced_ids(cutoff, after_id) do
    predicates =
      Enum.map_join(Files.object_references(), " AND ", fn {table, column} ->
        "NOT EXISTS (SELECT 1 FROM #{table} AS reference " <>
          "WHERE reference.tenant_id = object.tenant_id AND reference.#{column} = object.id)"
      end)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT object.id::text FROM file_objects AS object
        WHERE object.tenant_id = $1::text::uuid AND object.created_at < $2
          AND ($3::text::uuid IS NULL OR object.id > $3::text::uuid)
          AND #{predicates}
        ORDER BY object.id LIMIT #{@collection_batch}
        """,
        [Repo.tenant_id!(), cutoff, after_id]
      )

    Enum.map(rows, &hd/1)
  end

  defp collect_one(id) do
    case Repo.transact_top_level(fn -> delete_and_enqueue_in_tx(id) end) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp delete_and_enqueue_in_tx(id) do
    with {:ok, object} <- lock(id),
         {:ok, _} <- Ankole.Ash.destroy(object, :remove),
         {:ok, job} <-
           Oban.insert(Files.Jobs.DeleteObject.new(%{"storage_key" => object.storage_key})) do
      {:ok, job}
    end
  end

  defp found({:ok, nil}), do: {:error, :not_found}
  defp found(result), do: result

  defp digest(<<value::binary-size(32)>>), do: {:ok, value}

  defp digest(<<value::binary-size(64)>>) do
    case Base.decode16(value, case: :mixed) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, :invalid_sha256}
    end
  end

  defp digest(_value), do: {:error, :invalid_sha256}

  defp object_result({:error, %{"code" => "not_found"}}), do: {:error, :not_found}
  defp object_result(result), do: result

  defp require_transaction!(operation) do
    unless Repo.in_transaction?(),
      do: raise(Ankole.Errors.Framework.TransactionRequired, operation: {__MODULE__, operation})
  end
end
