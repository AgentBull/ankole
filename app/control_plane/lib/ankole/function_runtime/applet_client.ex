defmodule Ankole.FunctionRuntime.AppletClient do
  @moduledoc "Connects one Applet call to a function replica without replaying executed code."
  alias Ankole.FunctionRuntime.{EndpointPool, HTTP}

  def inspect(source, limits, env \\ %{}) do
    result =
      HTTP.request(:post, "/v1/applet/inspect", %{
        source: source,
        env: env,
        timeout_ms: Keyword.get(limits, :timeout_ms, 5_000),
        memory_mb: Keyword.get(limits, :heap_mb, 64)
      })

    case result do
      {:ok, 200, body} ->
        with {:ok, decoded} <- Torque.decode(body), do: {:ok, decoded["routes"]}

      {:ok, 503, _} ->
        {:error, %{"code" => "applet_busy"}}

      {:error, :function_runtime_unavailable} ->
        {:error, %{"code" => "applet_busy"}}

      {:ok, _, body} ->
        with {:ok, decoded} <- Torque.decode(body), do: {:error, decoded}

      error ->
        error
    end
  end

  def start(package, context, limits, deadline \\ nil) do
    owner = self()
    run_id = Ash.UUIDv7.generate()

    deadline =
      deadline || System.monotonic_time(:millisecond) + Keyword.get(limits, :timeout_ms, 60_000)

    {:ok, pid} =
      Task.Supervisor.start_child(Ankole.FunctionRuntime.Tasks, fn ->
        monitor = Process.monitor(owner)

        case connect(package, context, limits, run_id, [], deadline) do
          {:ok, connection, endpoint, lease} ->
            outcome =
              try do
                outcome =
                  if System.monotonic_time(:millisecond) >= deadline do
                    {:aborted, failure(:handler_timeout)}
                  else
                    with {:ok, connection} <-
                           send_json(connection, %{
                             type: "start",
                             run_id: run_id,
                             context: context
                           }) do
                      loop(connection, owner, monitor, run_id, deadline)
                    else
                      {:error, _} -> {:aborted, failure(close_reason(deadline))}
                    end
                  end

                path = "/v1/applet/invocations/" <> run_id
                path = if match?({:completed, _}, outcome), do: path, else: path <> "?aborted=1"
                settle(endpoint, path, outcome)
              after
                Mint.HTTP.close(connection.conn)
                EndpointPool.release(lease)
              end

            case outcome do
              {_, result} -> done(owner, run_id, result)
              :cancelled -> :ok
            end

          {:error, reason} ->
            done(owner, run_id, failure(reason))
        end
      end)

    {:ok, pid, run_id}
  end

  def reply(pid, call_id, {:ok, value}),
    do: send(pid, {:reply, %{type: "reply", call_id: call_id, value: value}})

  def reply(pid, call_id, {:error, error}),
    do: send(pid, {:reply, %{type: "reply", call_id: call_id, error: error}})

  def cancel(pid), do: send(pid, :cancel)

  defp settle(endpoint, path, outcome) do
    case HTTP.at(endpoint, :delete, path, %{}, 5_000) do
      {:ok, 204, _} ->
        outcome

      error ->
        Ankole.Logging.warning(
          "function_runtime.invocation_cleanup_failed",
          "Function invocation cleanup failed",
          %{reason: inspect(error)}
        )

        case outcome do
          {:completed, _} -> outcome
          :cancelled -> :cancelled
          _ -> {:aborted, failure(:handler_error)}
        end
    end
  end

  defp connect(package, context, limits, run_id, excluded, deadline) do
    with :ok <- check_deadline(deadline),
         {:ok, endpoint, lease} <- EndpointPool.checkout(excluded) do
      query =
        URI.encode_query(%{
          run_id: run_id,
          tenant_id: package.tenant_id,
          page_id: context["applet"]["pageId"],
          revision: context["applet"]["revision"],
          sha256: package.sha256,
          timeout_ms: Keyword.get(limits, :timeout_ms, 60_000),
          memory_mb: Keyword.get(limits, :heap_mb, 128)
        })

      path = "/v1/applet/invoke?" <> query
      result = preflight(endpoint, path, deadline)

      result =
        case result do
          {:http, 428} ->
            case HTTP.at(
                   endpoint,
                   :put,
                   "/v1/applet/code/" <> package.sha256,
                   %{source: package.source, env: package.env},
                   remaining_timeout(deadline, 10_000)
                 ) do
              {:ok, 204, _} -> preflight(endpoint, path, deadline)
              other -> {:error, other}
            end

          other ->
            other
        end

      case result do
        {:ok, connection} ->
          {:ok, connection, endpoint, lease}

        failure ->
          HTTP.at(
            endpoint,
            :delete,
            "/v1/applet/invocations/" <> run_id <> "?aborted=1",
            %{},
            remaining_timeout(deadline, 5_000)
          )

          EndpointPool.release(lease)

          if excluded == [] and retryable?(failure) do
            EndpointPool.unavailable(endpoint)
            connect(package, context, limits, run_id, [endpoint.ip], deadline)
          else
            {:error, if(check_deadline(deadline) == :ok, do: failure, else: :handler_timeout)}
          end
      end
    end
  end

  defp preflight(endpoint, path, deadline) do
    with :ok <- check_deadline(deadline) do
      case HTTP.at(endpoint, :get, path, %{}, remaining_timeout(deadline, 10_000)) do
        {:ok, 204, _} -> upgrade(endpoint, path, deadline)
        {:ok, status, _} -> {:http, status}
        {:connect_error, reason} -> {:connect_error, reason}
        error -> error
      end
    end
  end

  defp retryable?({:http, 503}), do: true
  defp retryable?({:connect_error, _}), do: true
  defp retryable?(_), do: false

  defp upgrade(endpoint, path, deadline) do
    case Mint.HTTP.connect(endpoint.scheme, endpoint.ip, endpoint.port,
           hostname: endpoint.host,
           protocols: [:http1],
           mode: :passive,
           transport_opts: [timeout: remaining_timeout(deadline, 5_000)]
         ) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(
               if(endpoint.scheme == :https, do: :wss, else: :ws),
               conn,
               path,
               EndpointPool.authorization()
             ) do
          {:ok, conn, ref} ->
            handshake(conn, ref, nil, [], deadline)

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:connect_error, reason}
    end
  end

  defp handshake(conn, ref, status, headers, deadline) do
    case Mint.WebSocket.recv(conn, 0, remaining_timeout(deadline, 5_000)) do
      {:ok, conn, responses} ->
        status =
          Enum.reduce(responses, status, fn
            {:status, ^ref, value}, _ -> value
            _, value -> value
          end)

        headers =
          Enum.reduce(responses, headers, fn
            {:headers, ^ref, value}, _ -> value
            _, value -> value
          end)

        cond do
          check_deadline(deadline) != :ok ->
            Mint.HTTP.close(conn)
            {:error, :handler_timeout}

          status == 101 and headers != [] ->
            with {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, headers, mode: :active),
                 {:ok, conn} <- Mint.HTTP.set_mode(conn, :active),
                 do: {:ok, %{conn: conn, ws: ws, ref: ref}}

          is_integer(status) and status != 101 ->
            Mint.HTTP.close(conn)
            {:http, status}

          true ->
            handshake(conn, ref, status, headers, deadline)
        end

      {:error, conn, reason, _} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp remaining_timeout(deadline, maximum),
    do: max(1, min(maximum, deadline - System.monotonic_time(:millisecond)))

  defp check_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, :handler_timeout}
  end

  defp loop(connection, owner, monitor, run_id, deadline) do
    connection = Map.put(connection, :deadline, deadline)

    receive do
      {:reply, frame} ->
        case send_json(connection, frame) do
          {:ok, connection} -> loop(connection, owner, monitor, run_id, deadline)
          {:error, _} -> {:aborted, failure(close_reason(deadline))}
        end

      :cancel ->
        send_json(connection, %{type: "cancel", run_id: run_id})
        :cancelled

      {:DOWN, ^monitor, :process, _, _} ->
        send_json(connection, %{type: "cancel", run_id: run_id})
        :cancelled

      message ->
        case Mint.WebSocket.stream(connection.conn, message) do
          {:ok, conn, responses} ->
            {connection, terminal} =
              response_frames(%{connection | conn: conn}, responses, owner, run_id)

            terminal || loop(connection, owner, monitor, run_id, deadline)

          {:error, conn, _, responses} ->
            {_connection, terminal} =
              response_frames(%{connection | conn: conn}, responses, owner, run_id)

            terminal || {:aborted, failure(close_reason(deadline))}

          :unknown ->
            loop(connection, owner, monitor, run_id, deadline)
        end
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        send_json(connection, %{type: "cancel", run_id: run_id})
        {:aborted, failure(:handler_timeout)}
    end
  end

  defp response_frames(connection, responses, owner, run_id) do
    Enum.reduce(responses, {connection, nil}, fn
      _, {connection, terminal} when not is_nil(terminal) ->
        {connection, terminal}

      {:data, _, bytes}, {connection, terminal} ->
        case Mint.WebSocket.decode(connection.ws, bytes) do
          {:ok, ws, frames} ->
            frames(%{connection | ws: ws}, frames, owner, run_id, terminal)

          _ ->
            {connection, {:aborted, failure(:handler_error)}}
        end

      _, acc ->
        acc
    end)
  end

  defp frames(connection, frames, owner, run_id, terminal) do
    Enum.reduce(frames, {connection, terminal}, fn
      _, {connection, terminal} when not is_nil(terminal) ->
        {connection, terminal}

      {:text, json}, {connection, terminal} ->
        case Torque.decode(json) do
          {:ok, %{"type" => "call", "run_id" => ^run_id} = frame} ->
            send(
              owner,
              {:applet_runtime, run_id, :call, frame["call_id"], frame["operation"],
               frame["args"]}
            )

            {connection, terminal}

          {:ok, %{"type" => "done", "run_id" => ^run_id, "outcome" => outcome}} ->
            {connection, {:completed, outcome}}

          _ ->
            {connection, terminal}
        end

      {:ping, payload}, {connection, terminal} ->
        case send_frame(connection, {:pong, payload}) do
          {:ok, connection} ->
            {connection, terminal}

          {:error, _} ->
            {connection, {:aborted, failure(close_reason(connection.deadline))}}
        end

      {:close, _, _}, {connection, nil} ->
        {connection, {:aborted, failure(close_reason(connection.deadline))}}

      _, acc ->
        acc
    end)
  end

  defp close_reason(deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: :handler_timeout, else: :handler_error
  end

  defp send_json(connection, frame), do: send_frame(connection, {:text, Torque.encode!(frame)})

  defp send_frame(connection, frame) do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(connection.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(connection.conn, connection.ref, bytes) do
      {:ok, %{connection | conn: conn, ws: ws}}
    else
      {:error, _, reason} -> {:error, reason}
    end
  end

  defp done(owner, run_id, outcome),
    do: send(owner, {:applet_runtime, run_id, :done, outcome})

  defp failure({:http, 503}), do: failure(:applet_busy)
  defp failure(:function_runtime_unavailable), do: failure(:applet_busy)
  defp failure({:error, reason}), do: failure(reason)

  defp failure(reason),
    do: %{
      "status" =>
        case reason do
          :handler_timeout -> 504
          :applet_busy -> 503
          _ -> 500
        end,
      "body" => %{
        "error" => %{
          "code" => to_string(if(is_atom(reason), do: reason, else: :handler_error)),
          "message" => "Applet invocation failed",
          "details" => nil
        }
      },
      "logs" => []
    }
end
