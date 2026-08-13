defmodule FakeFeishu.StandaloneE2ETest do
  @moduledoc """
  End-to-end proof of the standalone tool: a real `FeishuOpenAPI.WS.Client`
  connects to the standalone server, the admin API (the CLI's transport)
  sends a user message, the bot receives it over real frames and replies over
  REST, and the CLI commands see both sides of the conversation.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias FakeFeishu.CLI
  alias FakeFeishu.CLI.HTTP
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Event.Dispatcher
  alias FeishuOpenAPI.WS

  test "a WS echo bot answers a CLI-sent message end to end" do
    start_supervised!(
      {FakeFeishu.Standalone, port: 0, apps: [{"cli_echo", "s", nil}], users: ["Alice"]}
    )

    base = "http://127.0.0.1:#{standalone_port()}"
    client = FeishuOpenAPI.Client.new("cli_echo", fn -> "s" end, base_url: base)

    dispatcher =
      Dispatcher.new()
      |> Dispatcher.on("im.message.receive_v1", fn _type, %Event{} = event ->
        message = event.content["message"]
        text = JSON.decode!(message["content"])["text"]

        {:ok, _reply} =
          FeishuOpenAPI.post(client, "im/v1/messages/:message_id/reply",
            path_params: %{message_id: message["message_id"]},
            body: %{msg_type: "text", content: JSON.encode!(%{text: "echo: " <> text})}
          )

        :ok
      end)

    start_supervised!({WS.Client, client: client, dispatcher: dispatcher})

    wait_until!("bot WS connection", fn ->
      match?({:ok, %{"connections" => 1}}, HTTP.get(base, "/sim/v1/status"))
    end)

    assert {:ok, %{"data" => %{"items" => [%{"chat_id" => "oc_sim_general"}]}}} =
             FeishuOpenAPI.get(client, "im/v1/chats")

    {:ok, ids} =
      HTTP.post(base, "/sim/v1/chats/oc_sim_general/messages", %{
        "text" => "ping",
        "mention_bot" => true
      })

    wait_until!("bot echo reply in transcript", fn ->
      {:ok, messages} = HTTP.get(base, "/sim/v1/chats/oc_sim_general/messages")

      Enum.any?(messages, fn message ->
        message["sender"] == "bot" and
          (message["text"] || "") =~ "echo: @_user_1 ping" and
          message["reply_to"] == ids["message_id"]
      end)
    end)

    working_card = JSON.encode!(%{"schema" => "2.0", "body" => %{"elements" => []}})

    assert {:ok, %{"data" => %{"message_id" => card_message_id}}} =
             FeishuOpenAPI.post(client, "im/v1/messages/:message_id/reply",
               path_params: %{message_id: ids["message_id"]},
               body: %{msg_type: "interactive", content: working_card}
             )

    terminal_card =
      JSON.encode!(%{
        "schema" => "2.0",
        "body" => %{"elements" => [%{"tag" => "markdown", "content" => "done"}]}
      })

    assert {:ok, %{"data" => %{"message_id" => ^card_message_id}}} =
             FeishuOpenAPI.request(client, :patch, "im/v1/messages/:message_id",
               path_params: %{message_id: card_message_id},
               body: %{content: terminal_card}
             )

    {:ok, messages} = HTTP.get(base, "/sim/v1/chats/oc_sim_general/messages")
    terminal_message = Enum.find(messages, &(&1["message_id"] == card_message_id))
    assert terminal_message["content"] == terminal_card
    assert terminal_message["text"] == "done"

    # The CLI binary path: argument parsing, command dispatch, and rendering.
    send_output =
      capture_io(fn -> CLI.main(["--url", base, "send", "ping-from-cli", "--mention-bot"]) end)

    assert send_output =~ "sent om_sim_"

    wait_until!("second echo in transcript", fn ->
      {:ok, messages} = HTTP.get(base, "/sim/v1/chats/oc_sim_general/messages")
      Enum.any?(messages, &((&1["text"] || "") =~ "echo: @_user_1 ping-from-cli"))
    end)

    {:ok, dm_ids} =
      HTTP.post(base, "/sim/v1/chats/oc_sim_p2p_cli_echo/messages", %{"text" => "dm-ping"})

    wait_until!("DM echo reply in transcript", fn ->
      {:ok, messages} = HTTP.get(base, "/sim/v1/chats/oc_sim_p2p_cli_echo/messages")

      Enum.any?(messages, fn message ->
        message["sender"] == "bot" and message["text"] == "echo: dm-ping" and
          message["reply_to"] == dm_ids["message_id"]
      end)
    end)

    ls_output = capture_io(fn -> CLI.main(["--url", base, "ls", "--chat", "oc_sim_general"]) end)
    assert ls_output =~ "ping-from-cli"
    assert ls_output =~ "echo: @_user_1 ping"

    status_output = capture_io(fn -> CLI.main(["--url", base, "status"]) end)
    assert status_output =~ ~s("connections":1)
  end

  defp standalone_port do
    {_id, pid, _type, _modules} =
      FakeFeishu.Standalone
      |> Supervisor.which_children()
      |> Enum.find(&match?({_id, _pid, _type, [Bandit]}, &1))

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp wait_until!(label, fun, deadline_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    wait_loop(label, fun, deadline)
  end

  defp wait_loop(label, fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for #{label}")

      true ->
        Process.sleep(50)
        wait_loop(label, fun, deadline)
    end
  end
end
