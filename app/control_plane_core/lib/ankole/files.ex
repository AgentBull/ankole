defmodule Ankole.Files do
  @moduledoc """
  Agent and Pod drives in the control plane.

  A drive file is one `drive_files` row: a path that names one byte content in
  `files`. The bytes are content addressed. The object key is
  `blobs/<sha256 hex>` in `Ankole.ObjectStore`, so one content is stored once
  however many Agents and paths name it.

  A write has two steps. `store/1` makes the bytes durable and returns their
  digest; `commit/4` then names digests at paths in one transaction. The
  collection job (`Ankole.Files.Jobs.CollectUnreferenced`) removes contents
  with no drive, Message attachment, or uncompleted Delivery reference after
  the one-day grace. The order of the steps and the
  `deleting` mark keep the two from racing:

    * `store/1` inserts or refreshes the `files` row first, which clears
      `deleting`, and writes the object after the row commits.
    * `commit/4` refreshes `last_referenced_at` with a row-locking update that
      skips rows marked `deleting`, so a content that collection has started to
      remove cannot get a new name.
    * Collection deletes the row and the object in one transaction that holds
      the row lock, and only for rows that it marked `deleting`.

  Paths are relative, use `/` as the separator, and have no empty, `.`, or
  `..` segment. A folder is only a path prefix; there are no folder rows.
  A file cannot also be the parent of another file.
  """

  import Ecto.Query

  alias Ankole.Files.Schemas.DriveFile
  alias Ankole.Files.Schemas.Blob
  alias Ankole.ObjectStore
  alias Ankole.Principals
  alias Ankole.Repo

  defguardp is_drive(drive) when is_binary(drive) or drive == :pod

  @max_path_bytes 1024
  @max_segment_bytes 255
  @hash_chunk_bytes 1024 * 1024
  @default_list_limit 1000
  @max_list_limit 5000

  @type drive :: String.t() | :pod
  @type sha256_hex :: String.t()
  @type commit_result :: %{files: [DriveFile.t()], deleted: non_neg_integer()}
  @type stored :: %{sha256: sha256_hex(), size: non_neg_integer()}
  @type upsert :: %{
          required(:path) => String.t(),
          required(:sha256) => sha256_hex(),
          required(:source) => String.t(),
          optional(:content_type) => String.t() | nil,
          optional(:mode) => non_neg_integer() | nil,
          optional(:conversation_id) => String.t() | nil,
          optional(:message_id) => String.t() | nil
        }

  @doc """
  Makes bytes durable and returns their digest and size.

  `content` is a binary or `{:file, path}` for a local file on this node. The
  object is always written, so a row left by a writer that stopped before its
  object was written becomes complete again.
  """
  @spec store(binary() | {:file, Path.t()}) :: {:ok, stored()} | {:error, term()}
  def store(content) do
    Repo.assert_outside_transaction!()

    with {:ok, digest, size} <- digest(content),
         :ok <- upsert_blob(digest, size),
         :ok <- write_object(object_key(digest), content) do
      {:ok, %{sha256: Base.encode16(digest, case: :lower), size: size}}
    end
  end

  @doc """
  Names stored contents at paths and removes paths, in one transaction.

  Each upsert replaces the file at its path. A delete removes the path and
  every path under it; deletes run before upserts. The result lists the
  upserted files with their sizes and counts the removed files.
  `{:error, {:blob_missing, sha256}}` means that one content was never stored
  or is being collected; nothing is committed then.
  `{:error, {:path_conflict, parent, child}}` rejects a file that would also
  name a folder. The drive lock serializes changes to one Agent's path tree.
  """
  @spec commit(drive(), [upsert()], [String.t()]) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(drive, upserts, deletes \\ []) when is_drive(drive) do
    Repo.transact(fn repo -> commit(repo, drive, upserts, deletes) end)
  end

  @doc """
  Same as `commit/3` inside the caller's transaction on `repo`.
  """
  @spec commit(module(), drive(), [upsert()], [String.t()]) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(repo, drive, upserts, deletes)
      when is_atom(repo) and is_drive(drive) and is_list(upserts) and
             is_list(deletes) do
    with {:ok, upserts} <- normalize_upserts(upserts),
         {:ok, deletes} <- normalize_paths(deletes),
         :ok <- lock_drive(repo, drive),
         {:ok, sizes} <- reference_blobs(repo, Enum.map(upserts, & &1.sha256)),
         deleted = deletes |> Enum.map(&delete_path_in_tx(repo, drive, &1)) |> Enum.sum(),
         :ok <- validate_path_tree(repo, drive, upserts) do
      now = DateTime.utc_now()

      files =
        Enum.map(upserts, fn upsert ->
          {:ok, file} = upsert_file(repo, drive, upsert, now)
          %{file | size: Map.fetch!(sizes, file.sha256)}
        end)

      {:ok, %{files: files, deleted: deleted}}
    end
  end

  @doc """
  Locks one Agent's drive until the caller's transaction ends.

  Library uses this lock to read a complete installed-Skill snapshot. A
  separate namespace avoids reversing the Principal and Agent row lock order.
  """
  @spec lock_drive(module(), drive()) :: :ok | {:error, term()}
  def lock_drive(repo, :pod) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["pod-drive:#{Repo.tenant_id!()}"])
    :ok
  end

  def lock_drive(repo, drive) do
    with {:ok, drive} <- Principals.normalize_uid(drive) do
      repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["agent-drive:#{drive}"])
      :ok
    end
  end

  @doc "Returns one drive file with its size."
  @spec fetch(drive(), String.t()) :: {:ok, DriveFile.t()} | {:error, term()}
  def fetch(drive, path) when is_drive(drive) do
    with {:ok, path} <- normalize_path(path) do
      case Repo.one(files_query(drive) |> where([file], file.path == ^path)) do
        %DriveFile{} = file -> {:ok, file}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "Returns the existing files at the requested paths in one drive."
  @spec fetch_many(drive(), [String.t()]) :: {:ok, [DriveFile.t()]} | {:error, term()}
  def fetch_many(drive, paths) when is_drive(drive) and is_list(paths) do
    with {:ok, paths} <- normalize_paths(paths) do
      {:ok, Repo.all(from(file in files_query(drive), where: file.path in ^paths))}
    end
  end

  @doc "Reads one drive file into memory."
  @spec read(drive(), String.t()) :: {:ok, DriveFile.t(), binary()} | {:error, term()}
  def read(drive, path) do
    with {:ok, file} <- fetch(drive, path),
         {:ok, content} <- read_object(file.sha256) do
      {:ok, file, content}
    end
  end

  @doc """
  Reads one content by its SHA-256 digest.

  An intent attachment names its content this way, so the provider receives
  the bytes that the Agent attached even if the drive path changed since.
  """
  @spec read_content(sha256_hex()) :: {:ok, binary()} | {:error, term()}
  def read_content(sha256) do
    with {:ok, digest} <- decode_sha256(sha256) do
      read_object(digest)
    end
  end

  @doc "Copies frozen attachment bytes into a local file without requiring its old drive path."
  @spec read_content_to_file(sha256_hex(), Path.t()) :: :ok | {:error, term()}
  def read_content_to_file(sha256, local_path) do
    with {:ok, digest} <- decode_sha256(sha256), do: read_object_to_file(digest, local_path)
  end

  @doc "Copies one drive file into a local file on this node."
  @spec read_to_file(drive(), String.t(), Path.t()) :: {:ok, DriveFile.t()} | {:error, term()}
  def read_to_file(drive, path, local_path) do
    with {:ok, file} <- fetch(drive, path),
         :ok <- read_object_to_file(file.sha256, local_path) do
      {:ok, file}
    end
  end

  # A content whose object is missing reads as `:not_found`, like a missing
  # path, whichever read found it.
  defp read_object(digest), do: digest |> object_key() |> ObjectStore.read() |> object_result()

  defp read_object_to_file(digest, local_path),
    do: digest |> object_key() |> ObjectStore.read_to_file(local_path) |> object_result()

  defp object_result({:error, %{"code" => "not_found"}}), do: {:error, :not_found}
  defp object_result(result), do: result

  @doc """
  Lists drive files at a path, ordered by path.

  A path that names a file lists that file; a path that names a folder lists
  every file under it; `""` lists the whole drive. `after:` continues after one
  path and `limit:`
  bounds the page (default #{@default_list_limit}, at most #{@max_list_limit}).
  The result carries the files and the path to continue after, or `nil` on the
  last page. `snapshot: true` adds a digest of the complete folder's path,
  content, and mode manifest, read under the drive lock.
  """
  @spec list(drive(), String.t(), keyword()) ::
          {:ok, %{files: [DriveFile.t()], next_after: String.t() | nil}} | {:error, term()}
  def list(drive, prefix \\ "", opts \\ []) when is_drive(drive) do
    repo = Keyword.get(opts, :repo, Repo)
    limit = opts |> Keyword.get(:limit, @default_list_limit) |> min(@max_list_limit) |> max(1)

    if Keyword.get(opts, :snapshot, false) do
      repo.transact(fn repo ->
        with :ok <- lock_drive(repo, drive),
             {:ok, query} <- prefix_query(files_query(drive), prefix),
             {:ok, page} <-
               list(drive, prefix, Keyword.merge(opts, snapshot: false, repo: repo)) do
          manifest =
            query
            |> exclude(:select)
            |> order_by([file], asc: file.path)
            |> select([file], {file.path, file.sha256, file.mode})
            |> repo.all()

          revision =
            :crypto.hash(:sha256, :erlang.term_to_binary(manifest)) |> Base.encode16(case: :lower)

          {:ok, Map.put(page, :revision, revision)}
        end
      end)
    else
      list_page(repo, drive, prefix, opts, limit)
    end
  end

  defp list_page(repo, drive, prefix, opts, limit) do
    with {:ok, query} <- prefix_query(files_query(drive), prefix),
         {:ok, query} <- after_query(query, Keyword.get(opts, :after)) do
      files =
        query
        |> order_by([file], asc: file.path)
        |> limit(^(limit + 1))
        |> repo.all()

      {page, rest} = Enum.split(files, limit)
      next_after = if rest == [], do: nil, else: List.last(page).path
      {:ok, %{files: page, next_after: next_after}}
    end
  end

  @doc """
  Lists the direct children of a folder: its files and the names of its
  subfolders, each in path order and each bounded by `limit:` (default
  #{@default_list_limit}). `truncated` is true when either list stopped at
  the bound, so a reader never takes a partial folder for the whole one.
  """
  @spec list_children(drive(), String.t(), keyword()) ::
          {:ok, %{folders: [String.t()], files: [DriveFile.t()], truncated: boolean()}}
          | {:error, term()}
  def list_children(drive, prefix \\ "", opts \\ [])
      when is_drive(drive) do
    limit = opts |> Keyword.get(:limit, @default_list_limit) |> min(@max_list_limit) |> max(1)

    with {:ok, scope} <- children_scope(prefix) do
      {like_pattern, offset} = scope

      base =
        from(file in DriveFile,
          where: ^drive_scope(drive),
          where: like(file.path, ^like_pattern)
        )

      folders =
        base
        |> where([file], fragment("strpos(substr(?, ?), '/') > 0", file.path, ^offset))
        |> select([file], fragment("split_part(substr(?, ?), '/', 1)", file.path, ^offset))
        |> distinct(true)
        |> order_by([file], fragment("1"))
        |> limit(^(limit + 1))
        |> Repo.all()

      files =
        files_query(drive)
        |> where([file], like(file.path, ^like_pattern))
        |> where([file], fragment("strpos(substr(?, ?), '/') = 0", file.path, ^offset))
        |> order_by([file], asc: file.path)
        |> limit(^(limit + 1))
        |> Repo.all()

      {:ok,
       %{
         folders: Enum.take(folders, limit),
         files: Enum.take(files, limit),
         truncated: length(folders) > limit or length(files) > limit
       }}
    end
  end

  @doc """
  Moves one file, or a folder and every file under it, to another path.

  The contents do not move; the paths that name them change in one
  transaction, however many files the folder holds. An existing file at a
  target path fails the move with
  `:already_exists`. A folder cannot move into itself.
  """
  @spec move(drive(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def move(drive, from_path, to_path) when is_drive(drive) do
    with {:ok, from_path} <- normalize_path(from_path),
         {:ok, to_path} <- normalize_path(to_path),
         :ok <- validate_move_target(from_path, to_path) do
      Repo.transact(fn repo ->
        with :ok <- lock_drive(repo, drive) do
          # Remove the source paths before checking the final tree. A folder
          # can move up into its parent without conflicting with itself.
          {_count, sources} =
            from(file in DriveFile,
              where: ^drive_scope(drive),
              where: ^subtree(from_path),
              select: file
            )
            |> repo.delete_all()

          moved = Enum.map(sources, &%{&1 | path: moved_path(&1.path, from_path, to_path)})

          with :ok <- require_sources(sources),
               :ok <- validate_path_tree(repo, drive, moved),
               :ok <- insert_moved(repo, moved) do
            {:ok, length(moved)}
          end
        end
      end)
    end
  end

  @doc "Removes one path and every path under it. Returns how many files were removed."
  @spec delete(drive(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete(drive, path) when is_drive(drive) do
    with {:ok, path} <- normalize_path(path) do
      Repo.transact(fn repo ->
        with :ok <- lock_drive(repo, drive) do
          {:ok, delete_path_in_tx(repo, drive, path)}
        end
      end)
    end
  end

  @doc "Returns whether the drive already names one content at some path."
  @spec drive_has_content?(drive(), sha256_hex()) :: boolean()
  def drive_has_content?(drive, sha256) when is_drive(drive) do
    case decode_sha256(sha256) do
      {:ok, digest} ->
        Repo.exists?(
          from(file in DriveFile, where: ^drive_scope(drive), where: file.sha256 == ^digest)
        )

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Returns a fresh path for a temporary local file on this node.

  Callers delete the file when they are done with it.
  """
  @spec temp_path() :: Path.t()
  def temp_path do
    dir = Path.join(System.tmp_dir!(), "ankole-files")
    File.mkdir_p!(dir)
    Path.join(dir, Ecto.UUID.generate())
  end

  @doc "The object key of one content."
  @spec object_key(binary()) :: String.t()
  def object_key(<<_::binary-size(32)>> = digest),
    do: "blobs/" <> Base.encode16(digest, case: :lower)

  @doc """
  Validates a drive path and returns it unchanged.

  A path is relative, at most #{@max_path_bytes} bytes, and every segment is
  1 to #{@max_segment_bytes} bytes, not `.` or `..`, and free of NUL bytes.
  """
  @spec normalize_path(term()) :: {:ok, String.t()} | {:error, {:invalid_path, term()}}
  def normalize_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    valid? =
      String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
        not String.contains?(path, <<0>>) and
        Enum.all?(segments, &valid_segment?/1)

    if valid?, do: {:ok, path}, else: {:error, {:invalid_path, path}}
  end

  def normalize_path(path), do: {:error, {:invalid_path, path}}

  @doc "Returns the drive directory of a channel, unchanged by Session resets."
  @spec chat_directory(String.t()) :: String.t()
  def chat_directory(channel_id) when is_binary(channel_id) and channel_id != "" do
    segment = URI.encode(channel_id, &(&1 == ?: or URI.char_unreserved?(&1)))
    segment = if segment in [".", ".."], do: String.replace(segment, ".", "%2E"), else: segment
    "chats/" <> segment
  end

  @doc "Places a channel's file under its drive directory."
  @spec chat_path(String.t() | nil, String.t()) :: String.t()
  def chat_path(channel_id, path) when is_binary(channel_id),
    do: chat_directory(channel_id) <> "/" <> path

  def chat_path(nil, path), do: path

  @doc "Checks the channel destination of a drive path. Shared paths have no channel restriction."
  @spec verify_delivery(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def verify_delivery("chats/" <> _rest = path, channel_id) do
    if is_binary(channel_id) and channel_id != "" and
         String.starts_with?(path, chat_directory(channel_id) <> "/"),
       do: :ok,
       else: {:error, {:file_channel_mismatch, path}}
  end

  def verify_delivery(_shared_path, _channel_id), do: :ok

  @doc """
  Returns the drive folder for a content that arrives with a file name.

  Inbound attachments, generated images, and sent files land at
  `<folder>/<first 16 digest hex digits>/<file name>`, so the same content with
  the same name always has the same path.
  """
  @spec content_path(String.t(), sha256_hex(), String.t()) :: String.t()
  def content_path(folder, sha256, name)
      when folder in ["inbox", "generated", "sent"] and is_binary(sha256) do
    Enum.join([folder, String.slice(sha256, 0, 16), file_name(name)], "/")
  end

  @doc "Makes a provider-supplied file name safe as one drive path segment."
  @spec file_name(term()) :: String.t()
  def file_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[\x00-\x1f\/\\]+/u, "_")
    |> String.trim()
    |> truncate_bytes(@max_segment_bytes)
    |> case do
      segment when segment in ["", ".", ".."] -> "file"
      segment -> segment
    end
  end

  def file_name(_name), do: "file"

  defp validate_path_tree(_repo, _drive, []), do: :ok

  defp validate_path_tree(repo, drive, upserts) do
    paths = MapSet.new(upserts, & &1.path)

    ancestors =
      Map.new(
        Enum.flat_map(paths, fn path ->
          path
          |> String.split("/")
          |> Enum.drop(-1)
          |> Enum.scan(&(&2 <> "/" <> &1))
          |> Enum.map(&{&1, path})
        end)
      )

    descendant =
      Enum.reduce(paths, dynamic(false), fn path, predicate ->
        prefix = Repo.escape_like(path) <> "/%"
        dynamic([file], ^predicate or like(file.path, ^prefix))
      end)

    conflict_path = dynamic([file], file.path in ^Map.keys(ancestors) or ^descendant)

    conflict =
      Enum.find(Map.keys(ancestors), &MapSet.member?(paths, &1)) ||
        repo.one(
          from(file in DriveFile,
            where: ^drive_scope(drive),
            where: ^conflict_path,
            select: file.path,
            order_by: file.path,
            limit: 1
          )
        )

    case conflict do
      nil ->
        :ok

      path ->
        case Map.fetch(ancestors, path) do
          {:ok, child} ->
            {:error, {:path_conflict, path, child}}

          :error ->
            parent = Enum.find(paths, &String.starts_with?(path, &1 <> "/"))
            {:error, {:path_conflict, parent, path}}
        end
    end
  end

  defp digest({:file, path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        with {:ok, hash} <- hash_file(path), do: {:ok, hash, size}

      {:ok, %File.Stat{}} ->
        {:error, {:invalid_source, :not_regular_file}}

      {:error, reason} ->
        {:error, {:invalid_source, reason}}
    end
  end

  defp digest(content) when is_binary(content),
    do: {:ok, :crypto.hash(:sha256, content), byte_size(content)}

  # A file that stats but cannot be read, for example one that only root may
  # read, is an invalid source, not a crash.
  defp hash_file(path) do
    hash =
      path
      |> File.stream!(@hash_chunk_bytes)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    {:ok, hash}
  rescue
    error in File.Error -> {:error, {:invalid_source, error.reason}}
  end

  defp upsert_blob(digest, size) do
    Repo.query!(
      """
      INSERT INTO files (sha256, size, deleting, created_at, last_referenced_at)
      VALUES ($1, $2, false, now(), now())
      ON CONFLICT (sha256) DO UPDATE
        SET last_referenced_at = now(), deleting = false
      """,
      [digest, size]
    )

    :ok
  end

  defp write_object(key, {:file, path}), do: ObjectStore.write_from_file(key, path)
  defp write_object(key, content) when is_binary(content), do: ObjectStore.write(key, content)

  defp normalize_upserts(upserts) do
    Enum.reduce_while(upserts, {:ok, []}, fn upsert, {:ok, acc} ->
      case normalize_upsert(upsert) do
        {:ok, upsert} -> {:cont, {:ok, [upsert | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, upserts} -> {:ok, Enum.reverse(upserts)}
      error -> error
    end
  end

  defp normalize_upsert(%{path: path, sha256: sha256, source: source} = upsert) do
    with {:ok, path} <- normalize_path(path),
         {:ok, digest} <- decode_sha256(sha256),
         :ok <- validate_source(source),
         {:ok, mode} <- normalize_mode(Map.get(upsert, :mode)) do
      {:ok,
       %{
         path: path,
         sha256: digest,
         source: source,
         mode: mode,
         content_type: content_type(Map.get(upsert, :content_type), path),
         conversation_id: Map.get(upsert, :conversation_id),
         message_id: Map.get(upsert, :message_id)
       }}
    end
  end

  defp normalize_upsert(upsert), do: {:error, {:invalid_upsert, upsert}}

  defp normalize_paths(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case normalize_path(path) do
        {:ok, path} -> {:cont, {:ok, [path | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  @doc """
  Keeps stored contents available until the caller commits their durable references.

  The caller must hold one transaction through this call and the reference write.
  A content already marked for collection is rejected.
  """
  @spec reference_contents_in_tx(module(), [sha256_hex()]) :: :ok | {:error, term()}
  def reference_contents_in_tx(repo, references) do
    with {:ok, digests} <-
           Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, digests} ->
             case decode_sha256(reference) do
               {:ok, digest} -> {:cont, {:ok, [digest | digests]}}
               error -> {:halt, error}
             end
           end),
         {:ok, _sizes} <- reference_blobs(repo, digests) do
      :ok
    end
  end

  # Refreshes every referenced content with a row-locking update that skips
  # rows marked `deleting`, and returns the size of each content.
  defp reference_blobs(repo, digests) do
    digests = Enum.uniq(digests)

    {_count, rows} =
      from(blob in Blob, where: blob.sha256 in ^digests and not blob.deleting, select: blob)
      |> repo.update_all(set: [last_referenced_at: DateTime.utc_now()])

    sizes = Map.new(rows, &{&1.sha256, &1.size})

    case Enum.find(digests, &(not Map.has_key?(sizes, &1))) do
      nil -> {:ok, sizes}
      missing -> {:error, {:blob_missing, Base.encode16(missing, case: :lower)}}
    end
  end

  defp upsert_file(repo, drive, upsert, now) do
    file = %DriveFile{
      agent_uid: if(drive == :pod, do: nil, else: drive),
      path: upsert.path,
      sha256: upsert.sha256,
      mode: upsert.mode,
      content_type: upsert.content_type,
      source: upsert.source,
      conversation_id: upsert.conversation_id,
      message_id: upsert.message_id,
      inserted_at: now,
      updated_at: now
    }

    repo.insert(file,
      on_conflict:
        {:replace,
         [
           :sha256,
           :mode,
           :content_type,
           :source,
           :conversation_id,
           :message_id,
           :updated_at
         ]},
      conflict_target: [:tenant_id, :agent_uid, :path],
      returning: true
    )
  end

  defp delete_path_in_tx(repo, drive, path) do
    {count, _rows} =
      DriveFile
      |> where([file], ^drive_scope(drive))
      |> where(^subtree(path))
      |> repo.delete_all()

    count
  end

  defp validate_move_target(from_path, to_path) do
    cond do
      from_path == to_path -> {:error, :same_path}
      String.starts_with?(to_path, from_path <> "/") -> {:error, :move_into_itself}
      true -> :ok
    end
  end

  defp require_sources([]), do: {:error, :not_found}
  defp require_sources(_sources), do: :ok

  defp moved_path(path, from_path, to_path) when path == from_path, do: to_path

  defp moved_path(path, from_path, to_path),
    do: to_path <> String.replace_prefix(path, from_path, "")

  @move_fields [
    :agent_uid,
    :path,
    :sha256,
    :mode,
    :content_type,
    :source,
    :conversation_id,
    :message_id,
    :inserted_at
  ]

  # The sources are already gone, so a file at a target path is another file.
  # The insert skips that row and the move fails in the same statement,
  # so a file that a concurrent commit put there stays. One statement takes at
  # most 65535 parameters; 1000 rows of the moved fields stay well below that.
  defp insert_moved(repo, moved) do
    now = DateTime.utc_now()

    moved
    |> Enum.map(
      &(&1
        |> Map.take(@move_fields)
        |> Map.put(:tenant_id, Repo.tenant_id!())
        |> Map.put(:updated_at, now))
    )
    |> Enum.chunk_every(1000)
    |> Enum.reduce_while(:ok, fn rows, :ok ->
      {count, _rows} =
        repo.insert_all(DriveFile, rows,
          on_conflict: :nothing,
          conflict_target: [:tenant_id, :agent_uid, :path]
        )

      if count == length(rows), do: {:cont, :ok}, else: {:halt, {:error, :already_exists}}
    end)
  end

  defp children_scope(prefix) when prefix in ["", nil], do: {:ok, {"%", 1}}

  defp children_scope(prefix) do
    with {:ok, prefix} <- normalize_path(prefix) do
      # PostgreSQL `substr` counts characters, not bytes.
      offset = length(String.to_charlist(prefix)) + 2
      {:ok, {Repo.escape_like(prefix) <> "/%", offset}}
    end
  end

  defp drive_scope(:pod), do: dynamic([file], is_nil(file.agent_uid))
  defp drive_scope(drive), do: dynamic([file], file.agent_uid == ^drive)

  defp files_query(drive) do
    from(file in DriveFile,
      join: blob in assoc(file, :blob),
      where: ^drive_scope(drive),
      select_merge: %{size: blob.size}
    )
  end

  defp subtree(path),
    do: dynamic([file], file.path == ^path or like(file.path, ^(Repo.escape_like(path) <> "/%")))

  defp prefix_query(query, prefix) when prefix in ["", nil], do: {:ok, query}

  defp prefix_query(query, prefix) do
    with {:ok, prefix} <- normalize_path(prefix) do
      {:ok, where(query, ^subtree(prefix))}
    end
  end

  defp after_query(query, nil), do: {:ok, query}

  defp after_query(query, after_path) when is_binary(after_path),
    do: {:ok, where(query, [file], file.path > ^after_path)}

  defp after_query(_query, after_path), do: {:error, {:invalid_path, after_path}}

  defp valid_segment?(segment),
    do: segment not in ["", ".", ".."] and byte_size(segment) <= @max_segment_bytes

  defp decode_sha256(<<hex::binary-size(64)>>) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, {:invalid_sha256, hex}}
    end
  end

  defp decode_sha256(<<_::binary-size(32)>> = digest), do: {:ok, digest}
  defp decode_sha256(value), do: {:error, {:invalid_sha256, value}}

  defp validate_source(source) do
    if source in DriveFile.sources(), do: :ok, else: {:error, {:invalid_source, source}}
  end

  defp normalize_mode(nil), do: {:ok, 0o644}
  defp normalize_mode(mode) when is_integer(mode) and mode in 0..0o777, do: {:ok, mode}
  defp normalize_mode(mode), do: {:error, {:invalid_mode, mode}}

  defp content_type(type, path) do
    case type do
      type when is_binary(type) and type != "" -> String.downcase(type)
      _missing -> MIME.from_path(path)
    end
  end

  defp truncate_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_bytes(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme
      if byte_size(next) > max_bytes, do: {:halt, acc}, else: {:cont, next}
    end)
  end
end
