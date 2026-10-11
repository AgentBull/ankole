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

  Errors are maps with the string keys `"code"` and `"message"`. A missing
  object has the code `"not_found"`.
  """

  alias Ankole.Kernel, as: NativeKernel

  @type store :: NativeKernel.object_store()
  @type error :: %{required(String.t()) => String.t()}

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

  @doc "Deletes one object. Deleting a missing object succeeds."
  @spec delete(store(), String.t()) :: :ok | {:error, error()}
  def delete(store, key) when is_binary(key) do
    call(&NativeKernel.object_store_delete_nif(store, key, self(), &1))
  end

  defp call(start_native) do
    ref = make_ref()

    case start_native.(ref) do
      :ok ->
        receive do
          {:object_store, ^ref, result} -> result
        end

      {:error, _reason} = error ->
        error
    end
  end
end
