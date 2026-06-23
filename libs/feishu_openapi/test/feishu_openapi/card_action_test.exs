defmodule FeishuOpenAPI.CardActionTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{CardAction, Crypto}
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

      headers = %{
        "x-lark-request-timestamp" => ts,
        "x-lark-request-nonce" => nonce,
        "x-lark-signature" => sig
      }

      assert {:ok, %CardAction{} = action} =
               CardAction.verify_and_decode(%{verification_token: "vt_x"}, body, headers)

      assert action.open_message_id == "om_123"
      assert action.user_id == "ou_456"
      assert action.action == %{"tag" => "button", "value" => %{"confirm" => true}}
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

    test "decrypts encrypted payloads before building the struct" do
      inner =
        Torque.encode!(%{
          "open_message_id" => "om_789",
          "user_id" => "ou_999",
          "action" => %{"tag" => "button", "value" => %{"id" => "1"}}
        })

      {:ok, encrypt} = Crypto.encrypt(inner, "ek_x")
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
