defmodule Ankole.Plugins.SlackConnectionIdentityTest.Socket do
  @behaviour WebSock
  def init(state) do
    frames = [
      %{"type" => "hello", "connection_info" => %{"app_id" => state.app_id}},
      %{
        "envelope_id" => "env-1",
        "type" => "events_api",
        "payload" => %{
          "event_id" => "Ev1",
          "event" => %{"type" => "message", "text" => "tenant input"}
        }
      }
    ]

    {:push, Enum.map(frames, &{:text, Torque.encode!(&1)}), state}
  end

  def handle_in({text, [opcode: :text]}, state) do
    send(state.test, {:socket_ack, Torque.decode!(text)})
    {:ok, state}
  end

  def handle_info(_, state), do: {:ok, state}
end

defmodule Ankole.Plugins.SlackConnectionIdentityTest.Plug do
  def init(opts), do: opts

  def call(conn, state),
    do: WebSockAdapter.upgrade(conn, Ankole.Plugins.SlackConnectionIdentityTest.Socket, state, [])
end

defmodule Ankole.Plugins.SlackConnectionIdentityTest do
  use ExUnit.Case, async: false
  alias SlackOpenAPI.SocketMode.{Client, Dispatcher}

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  test "a Socket Mode token for another app cannot dispatch or acknowledge input" do
    {pid, ref} = start_socket("A-other")

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :application_identity_mismatch}},
                   2_000

    refute_receive :dispatched
    refute_receive {:socket_ack, _}
  end

  test "the matching app dispatches input and acknowledges after the callback succeeds" do
    {pid, _ref} = start_socket("A-expected")
    assert_receive :dispatched, 2_000
    assert_receive {:socket_ack, %{"envelope_id" => "env-1"}}, 2_000
    :ok = Client.stop(pid)
  end

  test "failed bot identity lookup does not start or register a Socket Mode client" do
    alias Ankole.Plugins.SlackAdapter.{Config, ConnectionReconciler}

    previous = Application.fetch_env(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, Config, value)
        :error -> Application.delete_env(:ankole, Config)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/auth.test"
      Req.Test.json(conn, %{"ok" => false, "error" => "invalid_auth"})
    end)

    config = %{"appToken" => "xapp-failed-identity", "botToken" => "xoxb-failed-identity"}
    key = Config.connection_key(config)
    supervisor = Ankole.Plugins.SlackAdapter.ConnectionDynamicSupervisor
    children = DynamicSupervisor.which_children(supervisor)

    assert {:error, {:runtime_bot_identity, %SlackOpenAPI.Error{reason: "invalid_auth"}}} =
             ConnectionReconciler.start_client(key, config, [])

    assert Registry.lookup(Ankole.Plugins.SlackAdapter.ConnectionRegistry, key) == []
    assert DynamicSupervisor.which_children(supervisor) == children
  end

  defp start_socket(actual_id) do
    parent = self()
    {:ok, socket} = :gen_tcp.listen(0, ifaddr: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!(
      {Bandit,
       plug: {Ankole.Plugins.SlackConnectionIdentityTest.Plug, %{test: parent, app_id: actual_id}},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1},
       startup_log: false}
    )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"ok" => true, "url" => "ws://127.0.0.1:#{port}"})
    end)

    client =
      SlackOpenAPI.Client.new(app_token: "xapp-test", req_options: [plug: {Req.Test, __MODULE__}])

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on("message", fn _, _ ->
        send(parent, :dispatched)
        {:ok, :committed}
      end)

    {:ok, pid} =
      Client.start_link(
        client: client,
        dispatcher: dispatcher,
        expected_app_id: "A-expected",
        auto_reconnect: false
      )

    Process.unlink(pid)
    {pid, Process.monitor(pid)}
  end
end
