if Code.ensure_loaded?(Plug.Test) and Code.ensure_loaded?(FeishuOpenAPI.CardAction.Server) do
  defmodule FeishuOpenAPI.CardAction.ServerTest do
    use ExUnit.Case, async: true

    import Plug.Test

    alias FeishuOpenAPI.Crypto
    alias FeishuOpenAPI.CardAction.Handler
    alias FeishuOpenAPI.CardAction.Server

    test "responds with the challenge body" do
      handler = Handler.new(verification_token: "vt_x")

      conn =
        conn(
          :post,
          "/callback/card",
          Torque.encode!(%{
            "type" => "url_verification",
            "challenge" => "challenge_abc",
            "token" => "vt_x"
          })
        )
        |> Server.call(Server.init(handler: handler))

      assert conn.status == 200
      assert Torque.decode!(conn.resp_body) == %{"challenge" => "challenge_abc"}
    end

    test "serializes map responses from the card handler" do
      handler =
        Handler.new(
          verification_token: "vt_x",
          handler: fn _action ->
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

      conn =
        conn(:post, "/callback/card", body)
        |> Plug.Conn.put_req_header("x-lark-request-timestamp", ts)
        |> Plug.Conn.put_req_header("x-lark-request-nonce", nonce)
        |> Plug.Conn.put_req_header("x-lark-signature", sig)
        |> Server.call(Server.init(handler: handler))

      assert conn.status == 200

      assert Torque.decode!(conn.resp_body) == %{
               "toast" => %{"type" => "success", "content" => "ok"}
             }
    end

    test "returns the default success ack for nil handler results" do
      handler =
        Handler.new(
          verification_token: "vt_x",
          handler: fn _action -> :ok end
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

      conn =
        conn(:post, "/callback/card", body)
        |> Plug.Conn.put_req_header("x-lark-request-timestamp", ts)
        |> Plug.Conn.put_req_header("x-lark-request-nonce", nonce)
        |> Plug.Conn.put_req_header("x-lark-signature", sig)
        |> Server.call(Server.init(handler: handler))

      assert conn.status == 200
      assert Torque.decode!(conn.resp_body) == %{"msg" => "success"}
    end

    test "returns 400 for invalid signatures" do
      handler =
        Handler.new(
          verification_token: "vt_x",
          handler: fn _action -> :ok end
        )

      body =
        Torque.encode!(%{
          "open_message_id" => "om_123",
          "user_id" => "ou_456",
          "action" => %{"tag" => "button"}
        })

      conn =
        conn(:post, "/callback/card", body)
        |> Plug.Conn.put_req_header("x-lark-request-timestamp", "1711111")
        |> Plug.Conn.put_req_header("x-lark-request-nonce", "nonce-1")
        |> Plug.Conn.put_req_header("x-lark-signature", "bad-signature")
        |> Server.call(Server.init(handler: handler))

      assert conn.status == 400
      assert Torque.decode!(conn.resp_body) == %{"msg" => "invalid card callback: :bad_signature"}
    end
  end
end
