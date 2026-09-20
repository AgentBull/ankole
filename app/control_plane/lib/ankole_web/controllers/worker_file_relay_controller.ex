defmodule AnkoleWeb.WorkerFileRelayController do
  @moduledoc """
  Internal relay endpoint that Workers call with a one-time signed URL.

  `pull/2` streams the source of a pending user upload to the Worker. `push/2`
  receives the Worker's file bytes and hands them, one chunk at a time, to the
  consumer process that waits inside `Ankole.WorkerFiles.get/3`. The session
  token in the query string is the only credential; the session itself binds
  the Worker, path, method, byte bound, and expiry.
  """

  use AnkoleWeb, :controller

  alias Ankole.WorkerFiles.Relay

  @chunk_bytes 64 * 1024
  @ack_timeout_ms 30_000

  @spec pull(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pull(conn, %{"transfer_id" => transfer_id}) do
    case Relay.consume(transfer_id, "GET", conn.query_params["token"]) do
      {:ok, %{source: {:file, path}}} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_file(200, path)

      {:ok, %{source: {:binary, content}}} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, content)

      {:error, reason} ->
        reject(conn, reason)
    end
  end

  @spec push(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def push(conn, %{"transfer_id" => transfer_id}) do
    with {:ok, session} <- Relay.consume(transfer_id, "PUT", conn.query_params["token"]),
         {:ok, size} <- content_length(conn, session.max_bytes) do
      consumer_ref = Process.monitor(session.consumer)
      send(session.consumer, {:relay_opened, transfer_id, self(), size})

      case relay_body(conn, session, consumer_ref, 0) do
        {:ok, conn} ->
          send(session.consumer, {:relay_done, transfer_id})
          send_resp(conn, 200, "")

        {:error, reason, conn} ->
          send(session.consumer, {:relay_failed, transfer_id, reason})
          reject(conn, reason)
      end
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  # One chunk is in flight at a time: the consumer acknowledges each chunk
  # before the next read, so a slow user download bounds this process too.
  defp relay_body(conn, session, consumer_ref, received) do
    case read_body(conn, length: @chunk_bytes, read_length: @chunk_bytes) do
      {status, data, conn} when status in [:ok, :more] ->
        received = received + byte_size(data)

        cond do
          received > session.max_bytes ->
            {:error, :body_too_large, conn}

          data == "" and status == :ok ->
            {:ok, conn}

          true ->
            send(session.consumer, {:relay_chunk, session.transfer_id, data})

            case await_ack(session, consumer_ref) do
              :ok when status == :more -> relay_body(conn, session, consumer_ref, received)
              :ok -> {:ok, conn}
              {:error, reason} -> {:error, reason, conn}
            end
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}, conn}
    end
  end

  defp await_ack(session, consumer_ref) do
    transfer_id = session.transfer_id

    receive do
      {:relay_ack, ^transfer_id} -> :ok
      {:DOWN, ^consumer_ref, :process, _pid, _reason} -> {:error, :consumer_exited}
    after
      @ack_timeout_ms -> {:error, :consumer_timeout}
    end
  end

  defp content_length(conn, max_bytes) do
    with [value] <- get_req_header(conn, "content-length"),
         {size, ""} when size >= 0 <- Integer.parse(value) do
      if size > max_bytes, do: {:error, :body_too_large}, else: {:ok, size}
    else
      _missing -> {:error, :length_required}
    end
  end

  defp reject(conn, reason) do
    {status, code} =
      case reason do
        :invalid_token -> {401, "invalid_token"}
        :not_found -> {404, "unknown_transfer"}
        :method_mismatch -> {405, "method_mismatch"}
        :consumed -> {409, "transfer_consumed"}
        :expired -> {410, "transfer_expired"}
        :length_required -> {411, "length_required"}
        :body_too_large -> {413, "file_too_large"}
        :consumer_exited -> {499, "consumer_exited"}
        _other -> {500, "relay_failed"}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: %{code: code}}))
  end
end
