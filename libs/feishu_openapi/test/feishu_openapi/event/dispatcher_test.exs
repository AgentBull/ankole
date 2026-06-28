defmodule FeishuOpenAPI.Event.DispatcherTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{Client, Event}
  alias FeishuOpenAPI.Event.Dispatcher

  describe "challenge handshake" do
    test "returns {:challenge, echo} for url_verification when token matches" do
      d = Dispatcher.new(verification_token: "vt_x")

      body =
        Torque.encode!(%{
          "type" => "url_verification",
          "challenge" => "challenge_abc",
          "token" => "vt_x"
        })

      assert {:challenge, "challenge_abc"} = Dispatcher.dispatch(d, {:raw, body, %{}})
    end

    test "rejects a challenge whose token does not match" do
      d = Dispatcher.new(verification_token: "vt_x")
      body = Torque.encode!(%{"type" => "url_verification", "challenge" => "c", "token" => "bad"})
      assert {:error, :bad_verification_token} = Dispatcher.dispatch(d, {:raw, body, %{}})
    end

    test "missing verification_token on dispatcher side bypasses token check" do
      d = Dispatcher.new()
      body = Torque.encode!(%{"type" => "url_verification", "challenge" => "c"})
      assert {:challenge, "c"} = Dispatcher.dispatch(d, {:raw, body, %{}})
    end
  end

  describe "event routing" do
    test "registered handler receives event_type + %Event{}" do
      me = self()

      handler = fn event_type, event ->
        send(me, {:ran, event_type, event})
        :handled
      end

      d =
        Dispatcher.new()
        |> Dispatcher.on("im.message.receive_v1", handler)

      decoded = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "im.message.receive_v1"},
        "event" => %{"message_id" => "m-1"}
      }

      assert {:ok, :handled} = Dispatcher.dispatch(d, {:decoded, decoded})

      assert_receive {:ran, "im.message.receive_v1",
                      %Event{
                        type: "im.message.receive_v1",
                        content: %{"message_id" => "m-1"},
                        raw: ^decoded
                      }}
    end

    test "handler {:ok, result} is normalized to transport ack" do
      d =
        Dispatcher.new()
        |> Dispatcher.on("im.message.receive_v1", fn _event_type, _event ->
          {:ok, %{internal: :result}}
        end)

      decoded = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "im.message.receive_v1"},
        "event" => %{"message_id" => "m-1"}
      }

      assert {:ok, :ok} = Dispatcher.dispatch(d, {:decoded, decoded})
    end

    test "handler errors propagate instead of becoming webhook success" do
      d =
        Dispatcher.new()
        |> Dispatcher.on("im.message.receive_v1", fn _event_type, _event ->
          {:error, :route_failed}
        end)

      decoded = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "im.message.receive_v1"},
        "event" => %{"message_id" => "m-1"}
      }

      assert {:error, {:handler_failed, :route_failed}} =
               Dispatcher.dispatch(d, {:decoded, decoded})
    end

    test "verification_token is enforced for non-challenge events too" do
      d =
        Dispatcher.new(verification_token: "vt_x")
        |> Dispatcher.on("im.message.receive_v1", fn _t, _e -> :ok end)

      decoded = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "im.message.receive_v1", "token" => "bad"},
        "event" => %{"message_id" => "m-1"}
      }

      assert {:error, :bad_verification_token} = Dispatcher.dispatch(d, {:decoded, decoded})
    end

    test "trusted decoded events bypass webhook verification token" do
      me = self()

      handler = fn event_type, event ->
        send(me, {:ran, event_type, event})
        :handled
      end

      d =
        Dispatcher.new(verification_token: "vt_x")
        |> Dispatcher.on("im.message.receive_v1", handler)

      decoded = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "im.message.receive_v1"},
        "event" => %{"message_id" => "m-1"}
      }

      assert {:ok, :handled} = Dispatcher.dispatch(d, {:trusted_decoded, decoded})

      assert_receive {:ran, "im.message.receive_v1",
                      %Event{
                        type: "im.message.receive_v1",
                        content: %{"message_id" => "m-1"}
                      }}
    end

    test "unknown event types return :no_handler" do
      d = Dispatcher.new()

      decoded = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "does.not.exist"},
        "event" => %{}
      }

      assert {:ok, :no_handler} = Dispatcher.dispatch(d, {:decoded, decoded})
    end

    test "callback handlers and event handlers are separate registries" do
      d =
        Dispatcher.new()
        |> Dispatcher.on("x", fn _t, _e -> :event end)
        |> Dispatcher.on_callback("x", fn _t, _e -> :callback end)

      # Event handler wins when both are registered (event handlers take precedence)
      assert {:ok, :event} =
               Dispatcher.dispatch(
                 d,
                 {:decoded,
                  %{"schema" => "2.0", "header" => %{"event_type" => "x"}, "event" => %{}}}
               )
    end

    test "trusted decoded card action payloads route to card callback handlers" do
      me = self()

      d =
        Dispatcher.new()
        |> Dispatcher.on_callback("card.action.trigger", fn event_type, event ->
          send(me, {:card_action, event_type, event})
          :handled
        end)

      decoded = %{
        "open_message_id" => "om_card",
        "open_chat_id" => "oc_chat",
        "open_id" => "ou_user",
        "action" => %{
          "tag" => "button",
          "value" => %{"ankole_action" => "clarify_answer", "choice_value" => "Beta"}
        }
      }

      assert {:ok, :handled} = Dispatcher.dispatch(d, {:trusted_decoded, decoded})

      assert_receive {:card_action, "card.action.trigger", %Event{} = event}
      assert event.raw == decoded
      assert event.content == nil
    end
  end

  describe "signature verification" do
    test "skip_sign_verify: true bypasses signature checks" do
      d =
        Dispatcher.new(verification_token: "v", encrypt_key: "k", skip_sign_verify: true)
        |> Dispatcher.on("x", fn _t, _e -> :ok end)

      body =
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "x", "token" => "v"},
          "event" => %{}
        })

      assert {:ok, :ok} = Dispatcher.dispatch(d, {:raw, body, %{}})
    end

    test "valid signature within the replay window is accepted" do
      encrypt_key = "ek_x"

      d =
        Dispatcher.new(encrypt_key: encrypt_key, verification_token: "vt_x")
        |> Dispatcher.on("x", fn _t, _e -> :ok end)

      body =
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "x", "token" => "vt_x"},
          "event" => %{}
        })

      ts = Integer.to_string(System.system_time(:second))
      nonce = "n1"
      sig = FeishuOpenAPI.Crypto.event_signature(ts, nonce, encrypt_key, body)

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:ok, :ok} = Dispatcher.dispatch(d, {:raw, body, headers})
    end

    test "stale timestamp outside the replay window is rejected even with a valid signature" do
      encrypt_key = "ek_x"

      d =
        Dispatcher.new(encrypt_key: encrypt_key, verification_token: "vt_x")
        |> Dispatcher.on("x", fn _t, _e -> :ok end)

      body =
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "x", "token" => "vt_x"},
          "event" => %{}
        })

      ts = Integer.to_string(System.system_time(:second) - 10_000)
      nonce = "n1"
      sig = FeishuOpenAPI.Crypto.event_signature(ts, nonce, encrypt_key, body)

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:error, :timestamp_skew} = Dispatcher.dispatch(d, {:raw, body, headers})
    end

    test "skip_timestamp_check: true disables the replay window" do
      encrypt_key = "ek_x"

      d =
        Dispatcher.new(
          encrypt_key: encrypt_key,
          verification_token: "vt_x",
          skip_timestamp_check: true
        )
        |> Dispatcher.on("x", fn _t, _e -> :ok end)

      body =
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "x", "token" => "vt_x"},
          "event" => %{}
        })

      ts = "1711111"
      nonce = "n1"
      sig = FeishuOpenAPI.Crypto.event_signature(ts, nonce, encrypt_key, body)

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:ok, :ok} = Dispatcher.dispatch(d, {:raw, body, headers})
    end

    test "missing signature headers are rejected for non-challenge events when encrypt_key is configured" do
      d =
        Dispatcher.new(encrypt_key: "ek_x", verification_token: "vt_x")
        |> Dispatcher.on("x", fn _t, _e -> :ok end)

      body =
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "x", "token" => "vt_x"},
          "event" => %{}
        })

      assert {:error, :missing_signature_headers} = Dispatcher.dispatch(d, {:raw, body, %{}})
    end

    test "tampered body produces :bad_signature" do
      encrypt_key = "ek_x"

      d =
        Dispatcher.new(encrypt_key: encrypt_key, verification_token: "vt_x")
        |> Dispatcher.on("x", fn _t, _e -> :ok end)

      sig = FeishuOpenAPI.Crypto.event_signature("1", "n", encrypt_key, "original body")

      headers = %{
        "x-lark-request-timestamp" => "1",
        "x-lark-request-nonce" => "n",
        "x-lark-signature" => sig
      }

      # Send a different body — JSON is still valid but signature won't match.
      body =
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "x", "token" => "vt_x"},
          "event" => %{}
        })

      assert {:error, :bad_signature} = Dispatcher.dispatch(d, {:raw, body, headers})
    end
  end

  describe "fail-fast validation" do
    test "rejects invalid option types" do
      assert_raise ArgumentError, ~r/non-negative integer/, fn ->
        Dispatcher.new(max_skew_seconds: -1)
      end

      assert_raise ArgumentError, ~r/:client must be a FeishuOpenAPI.Client/, fn ->
        Dispatcher.new(client: :bad)
      end
    end

    test "accepts a FeishuOpenAPI.Client for the auto app_ticket handler" do
      client = Client.new("cli_dispatcher", "secret")
      dispatcher = Dispatcher.new(client: client, verification_token: "vt")

      assert %Dispatcher{client: ^client, verification_token: "vt"} = dispatcher
    end
  end
end
