defmodule Ankole.ObjectStore do
  @moduledoc """
  The control plane's object store for file-service bytes.

  The store is a bootstrap fact: `config/runtime.exs` builds its spec from
  `ANKOLE_FILES_STORE` and the matching `ANKOLE_FILES_*` variables. Each node
  opens the store on first use and keeps the native handle in
  `:persistent_term`. Only the file service (`Ankole.Files` and its collection
  job) calls it; the Worker never receives storage credentials.
  """

  alias Ankole.Kernel.ObjectStore, as: Native

  @cache_key {__MODULE__, :store}

  @type error :: Native.error() | :files_store_not_configured

  @doc "Returns the Kernel's backend-specific upload ceiling."
  def write_limit, do: with_store(fn store -> {:ok, Native.write_limit(store)} end)

  @doc "Reads one object into a binary."
  @spec read(String.t()) :: {:ok, binary()} | {:error, error()}
  def read(key), do: with_store(&Native.read(&1, key))

  @doc "Reads exactly `length` bytes at a zero-based offset through the native range reader."
  @spec read_range(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error()}
  def read_range(key, offset, length),
    do: with_store(&Native.read_range(&1, key, offset, length))

  @doc "Copies one object into a local file."
  @spec read_to_file(String.t(), Path.t()) :: :ok | {:error, error()}
  def read_to_file(key, path), do: with_store(&Native.read_to_file(&1, key, path))

  @doc "Writes a binary as one object."
  @spec write(String.t(), binary()) :: :ok | {:error, error()}
  def write(key, bytes), do: with_store(&Native.write(&1, key, bytes))

  @doc "Writes a local file as one object."
  @spec write_from_file(String.t(), Path.t()) :: :ok | {:error, error()}
  def write_from_file(key, path), do: with_store(&Native.write_from_file(&1, key, path))

  @doc "Streams binary chunks into one object and returns its committed SHA-256 and byte size."
  @spec write_stream(String.t(), Enumerable.t()) ::
          {:ok, Native.written_object()} | {:error, error()}
  def write_stream(key, source), do: with_store(&Native.write_stream(&1, key, source))

  @doc "Deletes one object. Deleting a missing object succeeds."
  @spec delete(String.t()) :: :ok | {:error, error()}
  def delete(key), do: with_store(&Native.delete(&1, key))

  defp with_store(fun) do
    with {:ok, store} <- store(), do: fun.(store)
  end

  defp store do
    case :persistent_term.get(@cache_key, nil) do
      nil -> open()
      store -> {:ok, store}
    end
  end

  defp open do
    case Application.get_env(:ankole, __MODULE__, [])[:spec] do
      spec when is_map(spec) ->
        with {:ok, store} <- Native.open(spec) do
          :persistent_term.put(@cache_key, store)
          {:ok, store}
        end

      nil ->
        {:error, :files_store_not_configured}
    end
  end
end
