defmodule Ankole.Kernel.ObjectStore do
  @moduledoc """
  Synchronous calls into the native object store.

  Each native call starts one operation on the kernel's Tokio runtime and
  returns at once. The result arrives as one `{:object_store, ref, result}`
  message to the calling process. The native retry and timeout layers bound
  every storage call, and the native task turns a panic into an error result
  with the code `"panic"`, so the receive needs no timeout of its own.

  A store is opened from a spec map:

    * `%{scheme: "fs", root: path}`
    * `%{scheme: "s3", bucket: name, region: region}` with the optional keys
      `endpoint`, `root`, `access_key_id`, and `secret_access_key`
    * `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, and
      `webdav`, with the matching OpenDAL service configuration fields.
      The control plane exposes their bootstrap variables in
      `docs/design-docs/Files.md`.

  Errors are maps with the string keys `"code"` and `"message"`. A missing
  object has the code `"not_found"`.
  """

  alias Ankole.Kernel, as: NativeKernel

  @doc "Maximum upload size for this backend, enforced by every native writer."
  def write_limit(store), do: NativeKernel.object_store_write_limit_nif(store)

  @type store :: NativeKernel.object_store()
  @type error :: %{required(String.t()) => String.t()}
  @type written_object :: %{sha256: String.t(), size: non_neg_integer()}
  @write_chunk_bytes 8 * 1024 * 1024

  @doc "Opens a store. Opening does no network I/O."
  @spec open(map()) :: {:ok, store()} | {:error, error()}
  def open(spec) when is_map(spec) do
    spec
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Torque.encode!()
    |> NativeKernel.object_store_open_nif()
  end

  @doc "Reads one object into a binary."
  @spec read(store(), String.t()) :: {:ok, binary()} | {:error, error()}
  def read(store, key) when is_binary(key) do
    call(&NativeKernel.object_store_read_nif(store, key, self(), &1))
  end

  @doc """
  Reads exactly `length` bytes starting at the zero-based `offset`.

  Both arguments are unsigned 64-bit integers. Their sum must fit in 64 bits.
  An empty range returns an empty binary without checking that the object exists.
  A non-empty range extending past the object returns a storage error.
  """
  @spec read_range(store(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error()}
  def read_range(store, key, offset, length) when is_binary(key) do
    call(&NativeKernel.object_store_read_range_nif(store, key, offset, length, self(), &1))
  end

  @doc "Copies one object into a local file."
  @spec read_to_file(store(), String.t(), Path.t()) ::
          :ok | {:error, error()}
  def read_to_file(store, key, path) when is_binary(key) do
    path = to_string(path)
    call(&NativeKernel.object_store_read_to_file_nif(store, key, path, self(), &1))
  end

  @doc "Writes a binary as one object, replacing an existing object."
  @spec write(store(), String.t(), binary()) :: :ok | {:error, error()}
  def write(store, key, bytes) when is_binary(key) and is_binary(bytes) do
    call(&NativeKernel.object_store_write_nif(store, key, bytes, self(), &1))
  end

  @doc "Writes a local file as one object, replacing an existing object."
  @spec write_from_file(store(), String.t(), Path.t()) :: :ok | {:error, error()}
  def write_from_file(store, key, path) when is_binary(key) do
    path = to_string(path)
    call(&NativeKernel.object_store_write_from_file_nif(store, key, path, self(), &1))
  end

  @doc """
  Writes an Enumerable of binaries and returns its SHA-256 and byte size after close.

  The calling process consumes the source once, waiting for each native write
  before requesting another chunk. Source exceptions propagate; cancellation,
  errors, and owner exit abort the writer. Backends without multipart support
  buffer the object in native memory.
  """
  @spec write_stream(store(), String.t(), Enumerable.t()) ::
          {:ok, written_object()} | {:error, error()}
  def write_stream(store, key, source) when is_binary(key) do
    ref = make_ref()

    with {:ok, writer} <- NativeKernel.object_store_writer_open_nif(store, key, ref) do
      try do
        with :ok <- await(ref),
             {:ok, digest, size} <- write_chunks(writer, source),
             :ok <- call(&NativeKernel.object_store_writer_close_nif(writer, &1)) do
          {:ok, %{sha256: Base.encode16(:crypto.hash_final(digest), case: :lower), size: size}}
        end
      after
        NativeKernel.object_store_writer_abort_nif(writer)
      end
    end
  end

  defp write_chunks(writer, source) do
    Enum.reduce_while(source, {:ok, :crypto.hash_init(:sha256), 0}, fn
      bytes, {:ok, digest, size} when is_binary(bytes) ->
        case write_chunk(writer, bytes) do
          :ok -> {:cont, {:ok, :crypto.hash_update(digest, bytes), size + byte_size(bytes)}}
          {:error, _} = error -> {:halt, error}
        end

      _, _ ->
        raise ArgumentError, "object store streams must yield binaries"
    end)
  end

  defp write_chunk(_writer, ""), do: :ok

  defp write_chunk(writer, bytes) when byte_size(bytes) > @write_chunk_bytes do
    <<chunk::binary-size(@write_chunk_bytes), rest::binary>> = bytes
    with :ok <- write_chunk(writer, chunk), do: write_chunk(writer, rest)
  end

  defp write_chunk(writer, bytes),
    do: call(&NativeKernel.object_store_writer_write_nif(writer, bytes, &1))

  @doc "Deletes one object. Deleting a missing object succeeds."
  @spec delete(store(), String.t()) :: :ok | {:error, error()}
  def delete(store, key) when is_binary(key) do
    call(&NativeKernel.object_store_delete_nif(store, key, self(), &1))
  end

  defp call(start_native) do
    ref = make_ref()

    case start_native.(ref) do
      :ok ->
        await(ref)

      {:error, _reason} = error ->
        error
    end
  end

  defp await(ref) do
    receive do
      {:object_store, ^ref, result} -> result
    end
  end
end
