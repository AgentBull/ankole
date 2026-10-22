defmodule AnkoleWeb.WorkerChannelTest do
  use AnkoleWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Ankole.RuntimeFabric
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.AgentWorkers.WorkerTracker
  alias Ankole.SessionsCase
  alias AnkoleWeb.RuntimeFabricSocket
  alias AnkoleWeb.WorkerChannel

  setup do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    :ok = SessionsCase.provision_worker(agent.uid)

    {:ok,
     worker_id: agent.uid,
     incarnation_id: "incarnation-#{System.unique_integer([:positive])}",
     token: Process.get({:worker_token, agent.uid})}
  end

  describe "socket connect" do
    test "authentication discovers the tenant with no inherited context", ctx do
      socket =
        Repo.without_tenant(fn ->
          assert {:ok, socket} =
                   connect(RuntimeFabricSocket, %{"worker_id" => ctx.worker_id},
                     connect_info: connect_info(ctx.token)
                   )

          socket
        end)

      assert {:ok, _, joined} =
               Repo.without_tenant(fn ->
                 subscribe_and_join(
                   socket,
                   WorkerChannel,
                   "worker",
                   join_payload(ctx)
                 )
               end)

      assert joined.assigns.worker_id == ctx.worker_id
      assert Repo.get!(AgentWorker, ctx.worker_id).tenant_id == ctx.tenant.id
      assert Repo.get!(AgentWorker, ctx.worker_id).transport_route == joined.assigns.connection_id
    end

    test "rejects a wrong auth token", %{worker_id: worker_id} do
      assert :error =
               connect(RuntimeFabricSocket, %{"worker_id" => worker_id},
                 connect_info: connect_info("wrong")
               )
    end

    test "rejects a missing worker id", %{token: token} do
      assert :error = connect(RuntimeFabricSocket, %{}, connect_info: connect_info(token))
    end

    test "rejects the credential of another Agent's Worker", %{token: token} do
      %{principal: other} = Ankole.PrincipalsFixtures.agent_fixture()
      :ok = SessionsCase.provision_worker(other.uid)

      assert :error =
               connect(RuntimeFabricSocket, %{"worker_id" => other.uid},
                 connect_info: connect_info(token)
               )
    end

    test "rejects the credential of a paused Worker", ctx do
      Repo.update_all(from(worker in AgentWorker, where: worker.agent_uid == ^ctx.worker_id),
        set: [state: :paused]
      )

      assert :error =
               connect(RuntimeFabricSocket, %{"worker_id" => ctx.worker_id},
                 connect_info: connect_info(ctx.token)
               )
    end

    test "accepts the generation credential and binds the Agent as the worker id", %{
      worker_id: worker_id,
      token: token
    } do
      assert {:ok, socket} =
               connect(RuntimeFabricSocket, %{"worker_id" => worker_id},
                 connect_info: connect_info(token)
               )

      assert socket.assigns.worker_id == worker_id
      assert socket.assigns.worker_generation == Repo.get!(AgentWorker, worker_id).generation
      assert RuntimeFabricSocket.id(socket) == "runtime_fabric_worker:" <> worker_id
    end
  end

  describe "join and admission" do
    test "a socket authenticated before replacement cannot join the new generation", ctx do
      old_socket = connect!(ctx)
      next_generation = "nextgen001"
      {:ok, credential} = AgentWorkers.issue_credential(ctx.worker_id, next_generation)

      Repo.update_all(from(worker in AgentWorker, where: worker.agent_uid == ^ctx.worker_id),
        set: [generation: next_generation] ++ Map.to_list(credential)
      )

      assert {:ok, next_token} = AgentWorkers.credential(Repo.get!(AgentWorker, ctx.worker_id))

      # The join payload cannot replace the generation proved by the socket.
      assert {:error, %{"reason" => "stale_worker_generation"}} =
               subscribe_and_join(
                 old_socket,
                 WorkerChannel,
                 "worker",
                 Map.put(join_payload(ctx), "generation", next_generation)
               )

      assert %AgentWorker{
               state: :starting,
               generation: ^next_generation,
               transport_route: nil,
               incarnation_id: nil
             } = Repo.get!(AgentWorker, ctx.worker_id)

      {_socket, route} = join!(%{ctx | token: next_token})

      assert %AgentWorker{generation: ^next_generation, transport_route: ^route} =
               Repo.get!(AgentWorker, ctx.worker_id)
    end

    test "a socket keeps its credential across pause and resume of the same generation", ctx do
      socket = connect!(ctx)

      Repo.update_all(from(worker in AgentWorker, where: worker.agent_uid == ^ctx.worker_id),
        set: [state: :paused]
      )

      Repo.update_all(from(worker in AgentWorker, where: worker.agent_uid == ^ctx.worker_id),
        set: [state: :starting]
      )

      assert {:ok, %{"connection_id" => route}, _socket} =
               subscribe_and_join(
                 socket,
                 WorkerChannel,
                 "worker",
                 join_payload(ctx)
               )

      assert Repo.get!(AgentWorker, ctx.worker_id).transport_route == route
    end

    test "rejects an unknown topic", ctx do
      assert {:error, %{"reason" => "unknown_topic"}} =
               ctx
               |> connect!()
               |> subscribe_and_join(
                 WorkerChannel,
                 "unknown",
                 join_payload(ctx)
               )
    end

    test "join admits the worker and registers its route in the tracker", ctx do
      {socket, route} = join!(ctx)

      assert %AgentWorker{state: :ready, transport_route: ^route} =
               Repo.get!(AgentWorker, ctx.worker_id)

      assert [{pid, meta}] = directory_entries(ctx.worker_id, route)
      assert pid == socket.channel_pid

      assert meta.incarnation_id == ctx.incarnation_id
      refute Map.has_key?(meta, :worker_id)
      refute Map.has_key?(meta, :connection_id)
      refute Map.has_key?(meta, :channel_pid)
      refute Map.has_key?(meta, :node)
    end

    test "rejects a join payload without the ready fields", ctx do
      assert {:error, %{"reason" => "max_slots_required"}} =
               ctx
               |> connect!()
               |> subscribe_and_join(
                 WorkerChannel,
                 "worker",
                 Map.delete(join_payload(ctx), "max_slots")
               )
    end

    test "a same-incarnation rejoin moves the route and closes the old connection", ctx do
      {old_socket, old_route} = join!(ctx)
      Process.unlink(old_socket.channel_pid)
      monitor = Process.monitor(old_socket.channel_pid)
      {_new_socket, new_route} = join!(ctx)
      refute old_route == new_route

      assert_receive {:DOWN, ^monitor, :process, _pid, {:shutdown, :worker_route_replaced}},
                     1_000

      assert %AgentWorker{state: :ready, transport_route: ^new_route} =
               Repo.get!(AgentWorker, ctx.worker_id)
    end

    test "rejects an envelope from an older protocol", ctx do
      {socket, _route} = join!(ctx)

      bytes =
        RuntimeFabric.encode_envelope(%{
          heartbeat_envelope(ctx)
          | protocol_version: 5,
            stream: :STREAM_CONTROL,
            transport_seq: 1
        })

      ref = push(socket, "control", {:binary, bytes})
      assert_reply ref, :error, %{"reason" => "invalid_envelope"}
    end

    test "rejects an oversized assembled Worker message before decoding", ctx do
      {socket, _route} = join!(ctx)
      ref = push(socket, "control", {:binary, :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)})
      assert_reply ref, :error, %{"reason" => "message_too_large"}
      ref = push(socket, "control", {:binary, "not-an-envelope"})
      assert_reply ref, :error, %{"reason" => "invalid_envelope"}
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
      # slots; the rejected message is accepted with the same sequence. The
      # tasks read PostgreSQL, so the waits allow for a slow machine.
      assert_push "reply", {:binary, _bytes}, 1_000
      assert_push "reply", {:binary, _bytes}, 1_000
      assert_reply Enum.at(refs, 0), :ok, %{}
      assert_reply Enum.at(refs, 1), :ok, %{}

      ref =
        push(socket, "durable", {:binary, sealed(rpc_request_envelope("probe-3"), :durable, 3)})

      assert_reply ref, :ok, %{"stream" => "durable"}, 1_000
      assert_push "reply", {:binary, _bytes}, 1_000
    end

    test "credits recover as messages complete and the cumulative sequence advances", ctx do
      {socket, _route} = join!(ctx)

      ref =
        push(socket, "durable", {:binary, sealed(rpc_request_envelope("probe-a"), :durable, 1)})

      # The RPC task may already have answered; the credit is the budget left
      # at reply time, never more than the configured two slots.
      assert_reply ref, :ok, %{"acked_seq" => 1, "message_credit" => credit_after_first}, 1_000
      assert credit_after_first in 0..2

      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :control, 1)})

      assert_reply ref,
                   :ok,
                   %{"stream" => "control", "acked_seq" => 1, "message_credit" => 32},
                   1_000

      assert_push "reply", {:binary, _bytes}, 1_000
    end
  end

  describe "commands from the control plane" do
    test "send_mandatory returns after the worker acknowledges", ctx do
      {socket, route} = join!(ctx)
      envelope = command_envelope()

      task =
        Task.async(
          Repo.bind_tenant(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
        )

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

          Task.async(
            Repo.bind_tenant(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
          )
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

      task =
        Task.async(
          Repo.bind_tenant(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
        )

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

          Task.async(
            Repo.bind_tenant(fn -> WorkerRoute.send_mandatory(target(ctx, route), envelope) end)
          )
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
        from(worker in AgentWorker, where: worker.agent_uid == ^ctx.worker_id),
        set: [transport_route: "replaced-elsewhere"]
      )

      assert {:error, :stale_route} =
               WorkerRoute.send_mandatory(target(ctx, route), command_envelope())

      assert %AgentWorker{state: :ready} = Repo.get!(AgentWorker, ctx.worker_id)
    end

    test "request_rpc resolves with the worker response", ctx do
      {socket, route} = join!(ctx)

      task =
        Task.async(
          Repo.bind_tenant(fn ->
            WorkerRoute.request_rpc(target(ctx, route), "test.probe", "ping", timeout_ms: 1_000)
          end)
        )

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
        Task.async(
          Repo.bind_tenant(fn ->
            WorkerRoute.request_rpc(target(ctx, route), "test.probe", <<>>, timeout_ms: 1_000)
          end)
        )

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
                "retryable" => false,
                "details_json" => %{}
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
    for operation <- [:send_mandatory, :request_rpc, :push] do
      @tag :worker_route_killed
      test "#{operation} returns unknown_route when its channel is killed during the call", ctx do
        {socket, route} = join!(ctx)
        channel = socket.channel_pid
        Process.unlink(channel)
        :ok = :sys.suspend(channel)

        on_exit(fn ->
          if Process.alive?(channel), do: Process.exit(channel, :kill)
        end)

        parent = self()
        private_payload = "private-worker-route-prompt-token"

        envelope =
          WorkerRoute.rpc_request_envelope("killed-route", "test.probe", private_payload, 5_000)

        log =
          capture_log(fn ->
            task =
              Task.async(
                Repo.bind_tenant(fn ->
                  send(parent, {:caller_ready, self()})
                  receive do: (:call -> :ok)

                  case unquote(operation) do
                    :send_mandatory ->
                      WorkerRoute.send_mandatory(target(ctx, route), envelope)

                    :push ->
                      WorkerRoute.push(target(ctx, route), envelope)

                    :request_rpc ->
                      WorkerRoute.request_rpc(target(ctx, route), "test.probe", private_payload,
                        timeout_ms: 5_000
                      )
                  end
                end)
              )

            assert_receive {:caller_ready, caller}, 1_000
            assert caller == task.pid
            :erlang.trace(caller, true, [:send])
            send(caller, :call)

            assert_receive {:trace, ^caller, :send, {:"$gen_call", _from, request}, ^channel},
                           1_000

            assert inspect(request) =~ private_payload
            monitor = Process.monitor(channel)
            Process.exit(channel, :kill)
            assert_receive {:DOWN, ^monitor, :process, ^channel, :killed}, 1_000

            assert {:error, :unknown_route} = Task.await(task, 1_000)
            assert WorkerRoute.retryable?(:unknown_route)
            refute_receive {:trace, ^caller, :send, {:"$gen_call", _, _}, ^channel}
          end)

        refute log =~ private_payload
      end
    end

    test "closing the admitted connection stales the worker and fails waiters", ctx do
      {socket, route} = join!(ctx)

      task =
        Task.async(
          Repo.bind_tenant(fn ->
            WorkerRoute.request_rpc(target(ctx, route), "test.probe", <<>>, timeout_ms: 5_000)
          end)
        )

      assert_push "command", {:binary, _bytes}

      Process.unlink(socket.channel_pid)
      close(socket)

      assert {:error, :socket_closed} = Task.await(task, 1_000)

      assert %AgentWorker{state: :stale, transport_route: nil} =
               Repo.get!(AgentWorker, ctx.worker_id)

      assert directory_entries(ctx.worker_id, route) == []
    end

    test "an old connection closing after a reconnect does not stale the worker", ctx do
      {old_socket, old_route} = join!(ctx)
      {_new_socket, new_route} = join!(ctx)
      refute old_route == new_route

      Process.unlink(old_socket.channel_pid)
      close(old_socket)

      assert %AgentWorker{state: :ready, transport_route: ^new_route} =
               Repo.get!(AgentWorker, ctx.worker_id)

      assert directory_entries(ctx.worker_id, old_route) == []
      assert [_entry] = directory_entries(ctx.worker_id, new_route)
    end

    @tag :capture_log
    test "a crashing RPC handler answers rpc_error and the connection stays open", ctx do
      # An invalid gateway URL makes the API key handler raise.
      config_owner = Ankole.Sessions.AIGatewayAPIKeyBroker
      previous = Application.fetch_env(:ankole, config_owner)
      Application.put_env(:ankole, config_owner, base_url: :invalid_test_value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ankole, config_owner, value)
          :error -> Application.delete_env(:ankole, config_owner)
        end
      end)

      {socket, route} = join!(ctx)

      request = %FabricProto.Envelope{
        message_id: "request-handler-crash",
        body:
          {:rpc_request,
           %FabricProto.RPCRequest{
             request_id: "handler-crash",
             method: "ai_gateway.api_key_for.create_or_find_by_agent",
             payload: SessionsCase.encode_proto!(%FabricProto.AIGatewayAPIKeyRequest{})
           }}
      }

      ref = push(socket, "durable", {:binary, sealed(request, :durable, 1)})
      assert_reply ref, :ok, %{"stream" => "durable", "acked_seq" => 1}, 2_000
      assert_push "reply", {:binary, bytes}, 2_000

      assert {:ok,
              %FabricProto.Envelope{
                body:
                  {:rpc_error,
                   %FabricProto.RPCError{request_id: "handler-crash", code: "rpc_handler_failed"}}
              }} = RuntimeFabric.decode_and_validate(bytes)

      # The same connection carries the next message of the Worker.
      assert Process.alive?(socket.channel_pid)
      ref = push(socket, "control", {:binary, sealed(heartbeat_envelope(ctx), :control, 1)})
      assert_reply ref, :ok, %{"stream" => "control", "acked_seq" => 1}, 2_000

      assert %AgentWorker{state: :ready, transport_route: ^route} =
               Repo.get!(AgentWorker, ctx.worker_id)
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
      topic = "worker"
      token = "base64url.bearer.phx." <> Base.encode64(ctx.token, padding: false)
      path = "/runtime-fabric/worker/websocket?vsn=2.0.0&worker_id=#{ctx.worker_id}"

      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
      authority = connect_info(ctx.token).uri.authority

      {:ok, conn, ref} =
        Mint.WebSocket.upgrade(:ws, conn, path, [
          {"host", authority},
          {"sec-websocket-protocol", "phoenix, " <> token}
        ])

      {conn, websocket} = await_upgrade(conn, ref)

      join = Ankole.JSON.encode!(["1", "1", topic, "phx_join", join_payload(ctx)])
      {conn, websocket} = ws_send(conn, ref, websocket, {:text, join})
      {conn, websocket, [{:text, join_reply}]} = ws_receive(conn, ref, websocket)

      assert ["1", "1", ^topic, "phx_reply", %{"status" => "ok"}] =
               Ankole.JSON.decode!(join_reply)

      assert %AgentWorker{state: :ready, transport_route: route} =
               Repo.get!(AgentWorker, ctx.worker_id)

      [{channel_pid, _meta}] = directory_entries(ctx.worker_id, route)
      channel_monitor = Process.monitor(channel_pid)

      heartbeat = sealed(heartbeat_envelope(ctx), :control, 1)

      frame =
        <<0, 1, 1, byte_size(topic), 7, "1", "2", topic::binary, "control", heartbeat::binary>>

      {conn, websocket} = ws_send(conn, ref, websocket, {:binary, frame})
      {conn, _websocket, [{:text, heartbeat_reply}]} = ws_receive(conn, ref, websocket)

      assert ["1", "2", ^topic, "phx_reply", %{"status" => "ok"}] =
               Ankole.JSON.decode!(heartbeat_reply)

      Mint.HTTP.close(conn)
      assert_receive {:DOWN, ^channel_monitor, :process, ^channel_pid, _reason}, 5_000
      assert %AgentWorker{state: :stale} = Repo.get!(AgentWorker, ctx.worker_id)
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

  defp connect!(%{worker_id: worker_id, token: token}) do
    {:ok, socket} =
      connect(RuntimeFabricSocket, %{"worker_id" => worker_id}, connect_info: connect_info(token))

    socket
  end

  defp connect_info(token) do
    origin = AnkoleWeb.PodURL.site_origin(Phoenix.ConnTest.build_conn())
    %{auth_token: token, uri: URI.parse(origin)}
  end

  defp join_payload(%{incarnation_id: incarnation_id}) do
    %{
      "incarnation_id" => incarnation_id,
      "max_slots" => 2,
      "available_slots" => 2
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
        "worker",
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
    bytes =
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

  defp heartbeat_envelope(%{incarnation_id: incarnation_id}) do
    %FabricProto.Envelope{
      message_id: "heartbeat-#{System.unique_integer([:positive])}",
      body:
        {:worker_heartbeat,
         %FabricProto.WorkerHeartbeat{
           incarnation_id: incarnation_id,
           max_slots: 2,
           active_slots: 0,
           available_slots: 2
         }}
    }
  end

  defp rpc_request_envelope(request_id) do
    %FabricProto.Envelope{
      message_id: "request-#{request_id}",
      body:
        {:rpc_request,
         %FabricProto.RPCRequest{
           request_id: request_id,
           method: "worker_env.resolve",
           payload: <<>>
         }}
    }
  end

  defp rpc_response_envelope(request_id, payload) do
    %FabricProto.Envelope{
      message_id: "response-#{request_id}",
      body: {:rpc_response, %FabricProto.RPCResponse{request_id: request_id, payload: payload}}
    }
  end

  defp rpc_error_envelope(request_id) do
    %FabricProto.Envelope{
      message_id: "error-#{request_id}",
      body:
        {:rpc_error,
         %FabricProto.RPCError{
           request_id: request_id,
           code: "file_not_found",
           message: "missing",
           retryable: false,
           details_json: "{}"
         }}
    }
  end
end
