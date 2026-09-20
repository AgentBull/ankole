defmodule AnkoleWeb.WorkerChannelTest do
  use AnkoleWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.ActorRuntime.WorkerTracker
  alias AnkoleWeb.RuntimeFabricSocket
  alias AnkoleWeb.WorkerChannel

  setup do
    worker_id = "channel-worker-#{System.unique_integer([:positive])}"
    incarnation_id = "incarnation-#{System.unique_integer([:positive])}"

    {:ok, worker_id: worker_id, incarnation_id: incarnation_id, auth_key: WorkerAuthKey.ensure!()}
  end

  describe "socket connect" do
    test "rejects a wrong auth token", %{worker_id: worker_id} do
      assert :error =
               connect(RuntimeFabricSocket, %{"worker_id" => worker_id},
                 connect_info: %{auth_token: "wrong"}
               )
    end

    test "rejects a missing worker id", %{auth_key: key} do
      assert :error = connect(RuntimeFabricSocket, %{}, connect_info: %{auth_token: key})
    end

    test "accepts the worker key and binds the worker id", %{worker_id: worker_id, auth_key: key} do
      assert {:ok, socket} =
               connect(RuntimeFabricSocket, %{"worker_id" => worker_id},
                 connect_info: %{auth_token: key}
               )

      assert socket.assigns.worker_id == worker_id
      assert RuntimeFabricSocket.id(socket) == "runtime_fabric_worker:" <> worker_id
    end
  end

  describe "join and admission" do
    test "rejects a topic for another worker", ctx do
      assert {:error, %{"reason" => "identity_mismatch"}} =
               ctx
               |> connect!()
               |> subscribe_and_join(
                 WorkerChannel,
                 "worker/installation/other",
                 join_payload(ctx)
               )
    end

    test "rejects a topic outside the installation scope", ctx do
      assert {:error, %{"reason" => "unknown_topic"}} =
               ctx
               |> connect!()
               |> subscribe_and_join(
                 WorkerChannel,
                 "worker/tenant-a/#{ctx.worker_id}",
                 join_payload(ctx)
               )
    end

    test "join admits the worker and registers its route in the tracker", ctx do
      {socket, route} = join!(ctx)

      assert %AgentComputerWorker{status: "ready", transport_route: ^route} =
               Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)

      assert [{pid, meta}] = directory_entries(ctx.worker_id, route)
      assert pid == socket.channel_pid

      assert %{
               worker_id: worker_id,
               incarnation_id: incarnation_id,
               connection_id: ^route,
               node: node
             } = meta

      assert worker_id == ctx.worker_id
      assert incarnation_id == ctx.incarnation_id
      assert node == node()
    end

    test "rejects a join payload with another worker identity", ctx do
      assert {:error, %{"reason" => "identity_mismatch"}} =
               ctx
               |> connect!()
               |> subscribe_and_join(
                 WorkerChannel,
                 "worker/installation/#{ctx.worker_id}",
                 Map.put(join_payload(ctx), "worker_id", "other")
               )

      assert Repo.get_by(AgentComputerWorker, worker_id: ctx.worker_id) == nil
    end

    test "rejects a join payload without the ready fields", ctx do
      assert {:error, %{"reason" => "max_turns_required"}} =
               ctx
               |> connect!()
               |> subscribe_and_join(
                 WorkerChannel,
                 "worker/installation/#{ctx.worker_id}",
                 Map.delete(join_payload(ctx), "max_turns")
               )
    end

    test "a same-incarnation rejoin moves the route to the new connection", ctx do
      {_old_socket, old_route} = join!(ctx)
      {_new_socket, new_route} = join!(ctx)
      refute old_route == new_route

      assert %AgentComputerWorker{status: "ready", transport_route: ^new_route} =
               Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)
    end

    test "a worker_ready envelope after join is an ordinary lifecycle message", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "control", {:binary, sealed(ready_envelope(ctx), :control, 1)})
      assert_reply ref, :ok, %{"stream" => "control", "acked_seq" => 1}
    end

    test "rejects invalid bytes", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "control", {:binary, "not-an-envelope"})
      assert_reply ref, :error, %{"reason" => "invalid_envelope"}
    end
  end

  describe "streams" do
    test "a control body on the durable stream is wrong_stream", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "durable", {:binary, sealed(heartbeat_envelope(ctx), :durable, 1)})
      assert_reply ref, :error, %{"reason" => "wrong_stream"}
    end

    test "a stream field that does not match the event is wrong_stream", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :durable, 1)})
      assert_reply ref, :error, %{"reason" => "wrong_stream"}
    end

    test "control messages are answered after the projection update with credits", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :control, 1)})

      assert_reply ref, :ok, %{
        "stream" => "control",
        "acked_seq" => 1,
        "message_credit" => 32,
        "byte_credit" => 4_194_304
      }
    end

    test "a sequence gap is rejected with the expected number and does not advance", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :control, 2)})
      assert_reply ref, :error, %{"reason" => "bad_sequence", "expected" => 1}

      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :control, 1)})
      assert_reply ref, :ok, %{"acked_seq" => 1}
    end

    test "durable messages beyond the in-flight budget are answered flow_control", ctx do
      {socket, _route} = join!(ctx)
      # Two rpc_request envelopes hold their in-flight slot until the RPC task
      # answers; the test limit is two, so the third is refused before dispatch
      # and keeps its sequence number.
      refs =
        for index <- 1..3 do
          push(
            socket,
            "durable",
            {:binary, sealed(rpc_request_envelope("probe-#{index}"), :durable, index)}
          )
        end

      assert_reply List.last(refs), :error, %{
        "reason" => "flow_control",
        "stream" => "durable",
        "message_credit" => 0
      }

      # The two RPC tasks answer through `reply` pushes, which return their
      # slots; the rejected message is accepted with the same sequence.
      assert_push "reply", {:binary, _bytes}
      assert_push "reply", {:binary, _bytes}
      assert_reply Enum.at(refs, 0), :ok, %{}
      assert_reply Enum.at(refs, 1), :ok, %{}

      ref =
        push(socket, "durable", {:binary, sealed(rpc_request_envelope("probe-3"), :durable, 3)})

      assert_reply ref, :ok, %{"stream" => "durable"}
    end

    test "credits recover as messages complete and the cumulative sequence advances", ctx do
      {socket, _route} = join!(ctx)

      ref =
        push(socket, "durable", {:binary, sealed(rpc_request_envelope("probe-a"), :durable, 1)})

      # The RPC task may already have answered; the credit is the budget left
      # at reply time, never more than the configured two slots.
      assert_reply ref, :ok, %{"acked_seq" => 1, "message_credit" => credit_after_first}
      assert credit_after_first in 0..2

      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :control, 1)})
      assert_reply ref, :ok, %{"stream" => "control", "acked_seq" => 1, "message_credit" => 32}
    end
  end

  describe "commands from the control plane" do
    test "send_mandatory returns after the worker acknowledges", ctx do
      {socket, route} = join!(ctx)
      envelope = command_envelope()
      task = Task.async(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)

      assert_push "command", {:binary, bytes}

      assert {:ok, %FabricProto.Envelope{message_id: message_id, transport_seq: 1}} =
               RuntimeFabric.decode_and_validate(bytes)

      assert message_id == envelope.message_id
      refute_received {_ref, {:ok, :sent_or_queued}}

      push(socket, "ack", %{"acked_seq" => 1, "message_credit" => 8, "byte_credit" => 1_000_000})
      assert {:ok, :sent_or_queued} = Task.await(task, 1_000)
    end

    test "one cumulative ack resolves every command up to its sequence", ctx do
      {socket, route} = join!(ctx)

      tasks =
        for _index <- 1..2 do
          envelope = command_envelope()
          Task.async(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
        end

      assert_push "command", {:binary, first}
      assert_push "command", {:binary, second}

      assert {:ok, %FabricProto.Envelope{transport_seq: 1}} =
               RuntimeFabric.decode_and_validate(first)

      assert {:ok, %FabricProto.Envelope{transport_seq: 2}} =
               RuntimeFabric.decode_and_validate(second)

      push(socket, "ack", %{"acked_seq" => 2, "message_credit" => 8, "byte_credit" => 1_000_000})

      assert [{:ok, :sent_or_queued}, {:ok, :sent_or_queued}] =
               Enum.map(tasks, &Task.await(&1, 1_000))
    end

    test "a worker credit of zero is backpressure", ctx do
      {socket, route} = join!(ctx)
      envelope = command_envelope()
      task = Task.async(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
      assert_push "command", {:binary, _bytes}
      push(socket, "ack", %{"acked_seq" => 1, "message_credit" => 0, "byte_credit" => 0})
      assert {:ok, :sent_or_queued} = Task.await(task, 1_000)

      assert {:error, :backpressure} =
               WorkerRoute.send_mandatory(target(ctx, route), command_envelope())
    end

    test "send_mandatory times out without an acknowledgement", ctx do
      {_socket, route} = join!(ctx)

      assert {:error, :timeout} =
               WorkerRoute.send_mandatory(target(ctx, route), command_envelope())
    end

    test "send_mandatory reports backpressure past the pending-command limit", ctx do
      {_socket, route} = join!(ctx)

      tasks =
        for _index <- 1..2 do
          envelope = command_envelope()
          Task.async(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
        end

      assert_push "command", {:binary, _bytes}
      assert_push "command", {:binary, _bytes}

      assert {:error, :backpressure} =
               WorkerRoute.send_mandatory(target(ctx, route), command_envelope())

      Enum.each(tasks, &Task.await(&1, 1_000))
    end

    test "an unknown route is reported without a channel", ctx do
      assert {:error, :unknown_route} =
               WorkerRoute.send_mandatory(target(ctx, "no-such-route"), command_envelope())

      assert {:error, :unknown_route} =
               WorkerRoute.send_mandatory("no-such-local-route", command_envelope())
    end

    test "a directory entry that no longer matches the fence is stale_route", ctx do
      {_socket, route} = join!(ctx)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^ctx.worker_id),
        set: [transport_route: "replaced-elsewhere"]
      )

      assert {:error, :stale_route} =
               WorkerRoute.send_mandatory(target(ctx, route), command_envelope())

      assert %AgentComputerWorker{status: "ready"} =
               Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)
    end

    test "request_rpc resolves with the worker response", ctx do
      {socket, route} = join!(ctx)

      task =
        Task.async(fn ->
          WorkerRoute.request_rpc(target(ctx, route), "test.probe", "ping", timeout_ms: 1_000)
        end)

      assert_push "command", {:binary, bytes}

      assert {:ok, %FabricProto.Envelope{body: {:rpc_request, request}}} =
               RuntimeFabric.decode_and_validate(bytes)

      assert request.payload == "ping"

      ref =
        push(
          socket,
          "durable",
          {:binary, sealed(rpc_response_envelope(request.request_id, "pong"), :durable, 1)}
        )

      assert_reply ref, :ok, %{"stream" => "durable", "acked_seq" => 1}
      assert {:ok, "pong"} = Task.await(task, 1_000)
    end

    test "request_rpc resolves with the worker error", ctx do
      {socket, route} = join!(ctx)

      task =
        Task.async(fn ->
          WorkerRoute.request_rpc(target(ctx, route), "test.probe", <<>>, timeout_ms: 1_000)
        end)

      assert_push "command", {:binary, bytes}

      assert {:ok, %FabricProto.Envelope{body: {:rpc_request, request}}} =
               RuntimeFabric.decode_and_validate(bytes)

      ref =
        push(
          socket,
          "durable",
          {:binary, sealed(rpc_error_envelope(request.request_id), :durable, 1)}
        )

      assert_reply ref, :ok, %{}

      assert {:error,
              %{
                "code" => "file_not_found",
                "message" => "missing",
                "details_json" => %{"retryable" => false}
              }} = Task.await(task, 1_000)
    end

    test "push sends a reply event without waiting", ctx do
      {_socket, route} = join!(ctx)

      assert {:ok, :sent_or_queued} =
               WorkerRoute.push(target(ctx, route), rpc_response_envelope("answer-1", "done"))

      assert_push "reply", {:binary, bytes}

      assert {:ok,
              %FabricProto.Envelope{
                stream: :STREAM_DURABLE,
                transport_seq: 1,
                body: {:rpc_response, %{request_id: "answer-1"}}
              }} = RuntimeFabric.decode_and_validate(bytes)
    end
  end

  describe "connection lifecycle" do
    test "closing the admitted connection stales the worker and fails waiters", ctx do
      {socket, route} = join!(ctx)

      task =
        Task.async(fn ->
          WorkerRoute.request_rpc(target(ctx, route), "test.probe", <<>>, timeout_ms: 5_000)
        end)

      assert_push "command", {:binary, _bytes}

      Process.unlink(socket.channel_pid)
      close(socket)

      assert {:error, :socket_closed} = Task.await(task, 1_000)

      assert %AgentComputerWorker{status: "stale", stop_reason: "socket_closed"} =
               Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)

      assert directory_entries(ctx.worker_id, route) == []
    end

    test "an old connection closing after a reconnect does not stale the worker", ctx do
      {old_socket, old_route} = join!(ctx)
      {_new_socket, new_route} = join!(ctx)
      refute old_route == new_route

      Process.unlink(old_socket.channel_pid)
      close(old_socket)

      assert %AgentComputerWorker{status: "ready", transport_route: ^new_route} =
               Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)

      assert directory_entries(ctx.worker_id, old_route) == []
      assert [_entry] = directory_entries(ctx.worker_id, new_route)
    end
  end

  describe "over a real WebSocket" do
    test "authenticates with the Phoenix auth token, joins, and admits binary frames", ctx do
      server =
        start_supervised!(
          {Bandit,
           plug: AnkoleWeb.Endpoint,
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      topic = "worker/installation/#{ctx.worker_id}"
      token = "base64url.bearer.phx." <> Base.encode64(ctx.auth_key, padding: false)
      path = "/runtime-fabric/worker/websocket?vsn=2.0.0&worker_id=#{ctx.worker_id}"

      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

      {:ok, conn, ref} =
        Mint.WebSocket.upgrade(:ws, conn, path, [{"sec-websocket-protocol", "phoenix, " <> token}])

      {conn, websocket} = await_upgrade(conn, ref)

      join = Ankole.JSON.encode!(["1", "1", topic, "phx_join", join_payload(ctx)])
      {conn, websocket} = ws_send(conn, ref, websocket, {:text, join})
      {conn, websocket, [{:text, join_reply}]} = ws_receive(conn, ref, websocket)

      assert ["1", "1", ^topic, "phx_reply", %{"status" => "ok"}] =
               Ankole.JSON.decode!(join_reply)

      assert %AgentComputerWorker{status: "ready"} =
               Repo.get_by!(AgentComputerWorker, worker_id: ctx.worker_id)

      heartbeat = sealed(heartbeat_envelope(ctx), :control, 1)

      frame =
        <<0, 1, 1, byte_size(topic), 7, "1", "2", topic::binary, "control", heartbeat::binary>>

      {conn, websocket} = ws_send(conn, ref, websocket, {:binary, frame})
      {conn, _websocket, [{:text, heartbeat_reply}]} = ws_receive(conn, ref, websocket)

      assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok"}] =
               Ankole.JSON.decode!(heartbeat_reply)

      Mint.HTTP.close(conn)
    end
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, fn
                {:status, ^ref, status} -> status
                _other -> nil
              end)

            headers =
              Enum.find_value(responses, fn
                {:headers, ^ref, headers} -> headers
                _other -> nil
              end)

            if status do
              assert status == 101
              {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
              {conn, websocket}
            else
              await_upgrade(conn, ref)
            end

          {:error, _conn, reason, _responses} ->
            flunk("websocket upgrade failed: #{inspect(reason)}")
        end
    after
      5_000 -> flunk("websocket upgrade timed out")
    end
  end

  defp ws_send(conn, ref, websocket, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  defp ws_receive(conn, ref, websocket) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            data = for {:data, ^ref, data} <- responses, do: data

            case data do
              [] ->
                ws_receive(conn, ref, websocket)

              chunks ->
                {:ok, websocket, frames} =
                  Mint.WebSocket.decode(websocket, IO.iodata_to_binary(chunks))

                {conn, websocket, frames}
            end

          {:error, _conn, reason, _responses} ->
            flunk("websocket receive failed: #{inspect(reason)}")
        end
    after
      5_000 -> flunk("websocket frame timed out")
    end
  end

  defp connect!(%{worker_id: worker_id, auth_key: key}) do
    {:ok, socket} =
      connect(RuntimeFabricSocket, %{"worker_id" => worker_id}, connect_info: %{auth_token: key})

    socket
  end

  defp join_payload(%{worker_id: worker_id, incarnation_id: incarnation_id}) do
    %{
      "worker_id" => worker_id,
      "incarnation_id" => incarnation_id,
      "runtime" => "bun",
      "version" => "test",
      "max_turns" => 2,
      "available_turn_slots" => 2
    }
  end

  defp target(%{worker_id: worker_id}, route), do: %{worker_id: worker_id, transport_route: route}

  defp directory_entries(worker_id, route),
    do: Phoenix.Tracker.get_by_key(WorkerTracker, WorkerRoute.topic(worker_id), route)

  defp join!(ctx) do
    {:ok, %{"connection_id" => route}, socket} =
      ctx
      |> connect!()
      |> subscribe_and_join(
        WorkerChannel,
        "worker/installation/#{ctx.worker_id}",
        join_payload(ctx)
      )

    {socket, route}
  end

  @stream_enums %{
    control: :STREAM_CONTROL,
    durable: :STREAM_DURABLE,
    telemetry: :STREAM_TELEMETRY
  }

  defp sealed(envelope, stream, seq) do
    {:ok, bytes} =
      RuntimeFabric.seal_and_encode(%{
        envelope
        | stream: Map.fetch!(@stream_enums, stream),
          transport_seq: seq
      })

    bytes
  end

  defp command_envelope do
    WorkerRoute.rpc_request_envelope(
      "cmd-#{System.unique_integer([:positive])}",
      "test.probe",
      <<>>,
      1_000
    )
  end

  defp ready_envelope(%{worker_id: worker_id, incarnation_id: incarnation_id}) do
    %FabricProto.Envelope{
      message_id: "ready-#{System.unique_integer([:positive])}",
      body:
        {:worker_ready,
         %FabricProto.AgentComputerWorkerReady{
           worker_id: worker_id,
           incarnation_id: incarnation_id,
           runtime: "bun",
           version: "test",
           max_turns: 2,
           available_turn_slots: 2
         }}
    }
  end

  defp heartbeat_envelope(%{worker_id: worker_id, incarnation_id: incarnation_id}) do
    %FabricProto.Envelope{
      message_id: "heartbeat-#{System.unique_integer([:positive])}",
      body:
        {:worker_heartbeat,
         %FabricProto.AgentComputerWorkerHeartbeat{
           worker_id: worker_id,
           incarnation_id: incarnation_id,
           monotonic_ms: 1,
           runtime: "bun",
           version: "test",
           max_turns: 2,
           active_turns: 0,
           available_turn_slots: 2
         }}
    }
  end

  defp rpc_request_envelope(request_id) do
    %FabricProto.Envelope{
      message_id: "request-#{request_id}",
      correlation_id: request_id,
      body:
        {:rpc_request,
         %FabricProto.RPCRequest{
           request_id: request_id,
           method: "worker_env.resolve",
           agent_uid: "agent-missing",
           payload: <<>>
         }}
    }
  end

  defp rpc_response_envelope(request_id, payload) do
    %FabricProto.Envelope{
      message_id: "response-#{request_id}",
      correlation_id: request_id,
      body: {:rpc_response, %FabricProto.RPCResponse{request_id: request_id, payload: payload}}
    }
  end

  defp rpc_error_envelope(request_id) do
    %FabricProto.Envelope{
      message_id: "error-#{request_id}",
      correlation_id: request_id,
      body:
        {:rpc_error,
         %FabricProto.RPCError{
           request_id: request_id,
           code: "file_not_found",
           message: "missing",
           details_json: Ankole.JSON.encode!(%{"retryable" => false})
         }}
    }
  end
end
