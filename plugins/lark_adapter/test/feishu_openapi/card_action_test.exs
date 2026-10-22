defmodule FeishuOpenAPI.CardActionTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{CardAction, Crypto, CryptoTestSupport}
  alias FeishuOpenAPI.CardAction.Handler

  describe "verify_and_decode/3" do
    test "returns {:challenge, echo} for url_verification when token matches" do
      body =
        Torque.encode!(%{
          "type" => "url_verification",
          "challenge" => "challenge_abc",
          "token" => "vt_x"
        })

      assert {:challenge, "challenge_abc"} =
               CardAction.verify_and_decode(%{verification_token: "vt_x"}, body, %{})
    end

    test "rejects a challenge whose token does not match" do
      body =
        Torque.encode!(%{
          "type" => "url_verification",
          "challenge" => "challenge_abc",
          "token" => "bad"
        })

      assert {:error, :bad_verification_token} =
               CardAction.verify_and_decode(%{verification_token: "vt_x"}, body, %{})
    end

    test "accepts a valid signed plaintext action payload" do
      body =
        Torque.encode!(%{
          "open_message_id" => "om_123",
          "user_id" => "ou_456",
          "tenant_key" => "tenant_1",
          "action" => %{"tag" => "button", "value" => %{"confirm" => true}}
        })

      ts = "1711111"
      nonce = "nonce-1"
      sig = Crypto.card_signature(ts, nonce, "vt_x", body)

      for headers <- [
            %{
              "x-lark-request-timestamp" => ts,
              "x-lark-request-nonce" => nonce,
              "x-lark-signature" => sig
            },
            %{
              "X-Lark-Request-Timestamp" => [ts, "ignored"],
              "X-Lark-Request-Nonce" => [nonce],
              "X-Lark-Signature" => [sig]
            },
            [
              :ignored,
              {7, "ignored"},
              {"X-Lark-Request-Timestamp", ts},
              {:"x-lark-request-nonce", [nonce]},
              {"x-lark-signature", sig}
            ]
          ] do
        assert {:ok, %CardAction{} = action} =
                 CardAction.verify_and_decode(%{verification_token: "vt_x"}, body, headers)

        assert action.open_message_id == "om_123"
        assert action.user_id == "ou_456"
        assert action.action == %{"tag" => "button", "value" => %{"confirm" => true}}
      end
    end

    test "normalizes the current schema 2.0 operator and context shape" do
      payload = %{
        "schema" => "2.0",
        "header" => %{
          "event_type" => "card.action.trigger",
          "tenant_key" => "tenant_header"
        },
        "event" => %{
          "operator" => %{
            "user_id" => "user_123",
            "open_id" => "ou_456",
            "tenant_key" => "tenant_operator"
          },
          "context" => %{
            "open_message_id" => "om_123",
            "open_chat_id" => "oc_456"
          },
          "token" => "card_update_token",
          "action" => %{"name" => "choice-1", "value" => %{"choice" => "one"}}
        }
      }

      assert %CardAction{} = action = CardAction.from_payload(payload)
      assert action.user_id == "user_123"
      assert action.open_id == "ou_456"
      assert action.open_message_id == "om_123"
      assert action.open_chat_id == "oc_456"
      assert action.tenant_key == "tenant_operator"
      assert action.token == "card_update_token"
      assert action.type == "card.action.trigger"
      assert action.action == %{"name" => "choice-1", "value" => %{"choice" => "one"}}
    end

    test "rejects non-challenge requests without signature headers when verification is enabled" do
      body =
        Torque.encode!(%{
          "open_message_id" => "om_123",
          "user_id" => "ou_456",
          "action" => %{"tag" => "button"}
        })

      assert {:error, :missing_signature_headers} =
               CardAction.verify_and_decode(%{verification_token: "vt_x"}, body, %{})
    end

    test "legacy skip_sign_verify config cannot bypass signature checks" do
      body =
        Torque.encode!(%{
          "open_message_id" => "om_123",
          "user_id" => "ou_456",
          "action" => %{"tag" => "button"}
        })

      assert {:error, :missing_signature_headers} =
               CardAction.verify_and_decode(
                 %{verification_token: "vt_x", skip_sign_verify: true},
                 body,
                 %{}
               )
    end

    test "decrypts encrypted payloads before building the struct" do
      inner =
        Torque.encode!(%{
          "open_message_id" => "om_789",
          "user_id" => "ou_999",
          "action" => %{"tag" => "button", "value" => %{"id" => "1"}}
        })

      {:ok, encrypt} = CryptoTestSupport.encrypt(inner, "ek_x")
      body = Torque.encode!(%{"encrypt" => encrypt})

      ts = "1711112"
      nonce = "nonce-2"
      sig = Crypto.card_signature(ts, nonce, "vt_x", body)

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:ok, %CardAction{} = action} =
               CardAction.verify_and_decode(
                 %{verification_token: "vt_x", encrypt_key: "ek_x"},
                 body,
                 headers
               )

      assert action.open_message_id == "om_789"
      assert action.user_id == "ou_999"
    end
  end

  describe "handler dispatch" do
    test "callback errors keep private causes in telemetry and safe diagnostics in logs" do
      owner = self()
      handler_id = {__MODULE__, make_ref()}
      telemetry_event = [:feishu_openapi, :card_action, :handler_error]

      :ok =
        :telemetry.attach(
          handler_id,
          telemetry_event,
          fn name, _, metadata, pid ->
            if self() == pid, do: send(pid, {name, metadata})
          end,
          owner
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      secret = "private-card-action-should-not-escape"

      for {kind, failure} <- [error: "Elixir.ArgumentError", throw: "throw", exit: "exit"] do
        handler =
          Handler.new(
            handler: fn action ->
              value = action.action["private"]

              case kind do
                :error -> :erlang.binary_to_integer(value)
                :throw -> throw(value)
                :exit -> exit(value)
              end
            end
          )

        log =
          ExUnit.CaptureLog.capture_log([format: "$metadata$message\n", metadata: :all], fn ->
            assert {:error, {:handler_crashed, cause}} =
                     Handler.dispatch(handler, {:decoded, %{"action" => %{"private" => secret}}})

            if kind == :error,
              do: assert(%ArgumentError{} = cause),
              else: assert(cause == {kind, secret})

            assert_receive {^telemetry_event, %{kind: ^kind, reason: reason, stacktrace: frames}}
            assert is_list(frames)
            assert reason == if(kind == :error, do: cause, else: secret)
          end)

        assert log =~ "feishu_openapi.card_action.handler_crashed"
        assert log =~ "failure=#{failure}"
        assert log =~ "card_action_test.exs:"
        refute log =~ secret
      end
    end

    test "rejects the removed signature bypass option" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        Handler.new(skip_sign_verify: true)
      end
    end

    test "passes the normalized card action to the user handler" do
      me = self()

      handler =
        Handler.new(
          verification_token: "vt_x",
          handler: fn %CardAction{} = action ->
            send(me, {:handled, action})
            %{"toast" => %{"type" => "success", "content" => "ok"}}
          end
        )

      body =
        Torque.encode!(%{
          "open_message_id" => "om_123",
          "user_id" => "ou_456",
          "action" => %{"tag" => "button"}
        })

      ts = "1711111"
      nonce = "nonce-1"
      sig = Crypto.card_signature(ts, nonce, "vt_x", body)

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:ok, %{"toast" => %{"type" => "success"}}} =
               Handler.dispatch(handler, {:raw, body, headers})

      assert_receive {:handled, %CardAction{open_message_id: "om_123", user_id: "ou_456"}}
    end

    test "returns :handler_not_configured for non-challenge requests without a callback" do
      handler = Handler.new(verification_token: "vt_x")

      body =
        Torque.encode!(%{
          "open_message_id" => "om_123",
          "user_id" => "ou_456",
          "action" => %{"tag" => "button"}
        })

      ts = "1711111"
      nonce = "nonce-1"
      sig = Crypto.card_signature(ts, nonce, "vt_x", body)

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:error, :handler_not_configured} = Handler.dispatch(handler, {:raw, body, headers})
    end
  end
end
