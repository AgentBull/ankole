defmodule AnkoleWeb.SessionCookieStore do
  @moduledoc """
  Cookie-backed Phoenix session store sealed with Ankole Kernel AEAD.

  The browser still carries the full session payload, but it only sees the
  compact ciphertext returned by `Ankole.Kernel.aead_encrypt/2`.
  """

  @behaviour Plug.Session.Store

  require Logger

  alias Ankole.Kernel, as: NativeKernel

  @sid :ankole_aead_cookie
  @sub_key_id "phoenix.session_cookie"

  @impl true
  def init(opts) do
    %{
      key_context: Keyword.get(opts, :key_context, "default"),
      log: Keyword.get(opts, :log, :debug)
    }
  end

  @impl true
  def get(conn, raw_cookie, opts) when is_binary(raw_cookie) do
    with {:ok, key} <- encryption_key(conn, opts),
         {:ok, plaintext} <- decrypt(raw_cookie, key),
         {:ok, session} <- decode(plaintext) do
      {@sid, session}
    else
      {:error, reason} ->
        log_decode_failure(opts.log, reason)
        {nil, %{}}
    end
  end

  def get(_conn, _raw_cookie, _opts), do: {nil, %{}}

  @impl true
  def put(conn, _sid, term, opts) do
    binary = :erlang.term_to_binary(term)

    with {:ok, key} <- encryption_key(conn, opts),
         ciphertext when is_binary(ciphertext) <- NativeKernel.aead_encrypt(binary, key) do
      ciphertext
    else
      {:error, reason} ->
        raise ArgumentError, "could not encrypt session cookie: #{inspect(reason)}"

      other ->
        raise ArgumentError, "could not encrypt session cookie: #{inspect(other)}"
    end
  end

  @impl true
  def delete(_conn, _sid, _opts), do: :ok

  defp encryption_key(%Plug.Conn{secret_key_base: secret_key_base}, opts)
       when is_binary(secret_key_base) and byte_size(secret_key_base) >= 64 do
    case NativeKernel.derive_key(secret_key_base, @sub_key_id, opts.key_context) do
      key when is_binary(key) -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encryption_key(%Plug.Conn{secret_key_base: nil}, _opts) do
    {:error, "cookie store expects conn.secret_key_base to be set"}
  end

  defp encryption_key(%Plug.Conn{}, _opts) do
    {:error, "cookie store expects conn.secret_key_base to be at least 64 bytes"}
  end

  defp decrypt(raw_cookie, key) do
    case NativeKernel.aead_decrypt(raw_cookie, key) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(binary) do
    case Plug.Crypto.non_executable_binary_to_term(binary) do
      session when is_map(session) -> {:ok, session}
      _other -> {:error, "session payload is not a map"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp log_decode_failure(false, _reason), do: :ok

  defp log_decode_failure(level, reason) do
    Logger.log(
      level,
      "AnkoleWeb.SessionCookieStore could not decrypt incoming session cookie. Reason: #{inspect(reason)}"
    )
  end
end
