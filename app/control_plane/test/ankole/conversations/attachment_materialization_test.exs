defmodule Ankole.Conversations.AttachmentMaterializationTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Repo
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.Conversation
  import Ankole.Conversations.Assertions
  alias Ankole.Conversations.InboundBatches

  # The real adapter and SDK use a local HTTP stub. PostgreSQL stores the
  # normalized facts and the final actor input through the production owners.
  for outcome <- [:complete, :failed] do
    @outcome outcome

    test "DingTalk #{@outcome} media stores no temporary download code" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "dingtalk", :ignore, adapter: "dingtalk")
      previous = Req.default_options()
      on_exit(fn -> Req.default_options(previous) end)
      outcome = @outcome
      code = "temporary-dingtalk-#{System.unique_integer([:positive])}"

      Req.default_options(
        plug: fn conn ->
          case conn.request_path do
            "/v1.0/oauth2/accessToken" ->
              Req.Test.json(conn, %{"accessToken" => "fixture-token", "expireIn" => 7_200})

            "/v1.0/robot/messageFiles/download" ->
              dingtalk_download_response(conn, outcome)

            "/temporary-dingtalk" ->
              Plug.Conn.send_resp(conn, 200, "dingtalk bytes")

            _path ->
              conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"code" => "Unavailable"})
          end
        end
      )

      payload = %{
        "msgId" => "dingtalk-#{outcome}",
        "conversationId" => "fixture-dingtalk",
        "conversationType" => "1",
        "senderStaffId" => "staff",
        "msgtype" => "richText",
        "content" => %{"richText" => [%{"text" => "keep this fact"}, %{"downloadCode" => code}]}
      }

      context = context(agent.uid, "dingtalk")

      consumer =
        Ankole.Plugins.DingTalkAdapter.Inbound.chat_consumer(context, %{
          "clientId" => "fixture-app-#{System.unique_integer([:positive])}",
          "clientSecret" => "fixture-secret"
        })

      event = %DingTalkOpenAPI.Event{type: "CALLBACK", data: payload}

      assert {:ok, [result]} =
               Ankole.Plugins.DingTalkAdapter.Inbound.handle_message_receive("message", event, [
                 consumer
               ])

      assert_durable_media(result, outcome, [code, "downloadCode", "download_code"])

      assert result.message_observation.external_ref.raw_payload["content"]["richText"] == [
               %{"text" => "keep this fact"},
               %{}
             ]
    end

    test "WeCom #{@outcome} media stores no temporary URL or AES key" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "wecom", :ignore, adapter: "wecom")
      previous = Req.default_options()
      on_exit(fn -> Req.default_options(previous) end)
      outcome = @outcome
      key = :binary.copy(<<42>>, 32)
      aeskey = Base.encode64(key, padding: false)
      url = "https://media.test/temporary-wecom-#{System.unique_integer([:positive])}"
      body = "wecom bytes"
      pad = 32 - rem(byte_size(body), 32)

      ciphertext =
        :crypto.crypto_one_time(
          :aes_256_cbc,
          key,
          binary_part(key, 0, 16),
          body <> :binary.copy(<<pad>>, pad),
          true
        )

      Req.default_options(plug: &wecom_media_response(&1, outcome, ciphertext))

      payload = %{
        "msgid" => "wecom-#{outcome}",
        "chattype" => "single",
        "from" => %{"userid" => "staff"},
        "msgtype" => "mixed",
        "mixed" => %{
          "msg_item" => [
            %{"msgtype" => "text", "text" => %{"content" => "keep this fact"}},
            %{"msgtype" => "image", "image" => %{"url" => url, "aeskey" => aeskey}}
          ]
        }
      }

      consumer =
        Ankole.Plugins.WeComAdapter.Inbound.chat_consumer(context(agent.uid, "wecom"), %{})

      event =
        WeComOpenAPI.Bot.Event.from_frame(%{
          "cmd" => "aibot_msg_callback",
          "headers" => %{"req_id" => "fixture"},
          "body" => payload
        })

      assert {:ok, [result]} =
               Ankole.Plugins.WeComAdapter.Inbound.handle_message_receive("message", event, [
                 consumer
               ])

      assert_durable_media(result, outcome, [url, aeskey, "aeskey", "temp_url"])

      assert result.message_observation.external_ref.raw_payload["mixed"]["msg_item"] == [
               %{"msgtype" => "text", "text" => %{"content" => "keep this fact"}},
               %{"msgtype" => "image", "image" => %{}}
             ]
    end
  end

  defp dingtalk_download_response(conn, :complete),
    do: Req.Test.json(conn, %{"downloadUrl" => "https://media.test/temporary-dingtalk"})

  defp dingtalk_download_response(conn, :failed),
    do: conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"code" => "Unavailable"})

  defp wecom_media_response(conn, :complete, ciphertext) do
    conn
    |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="media.png"))
    |> Plug.Conn.send_resp(200, ciphertext)
  end

  defp wecom_media_response(conn, :failed, _ciphertext),
    do: Plug.Conn.send_resp(conn, 403, "unavailable")

  defp context(agent_uid, adapter) do
    AdapterContext.new(
      binding_id: Ankole.Signals.get_agent_binding!(agent_uid, adapter).id,
      agent_uid: agent_uid,
      binding_name: adapter,
      adapter: adapter,
      user_name: adapter
    )
  end

  defp assert_durable_media(result, outcome, forbidden) do
    entry = observation_snapshot(result.message_observation)
    assert [%{"materialization_state" => state} = attachment] = entry.attachments
    assert state == Atom.to_string(outcome)

    assert Ankole.Conversations.Attachments.stored?(attachment) ==
             (outcome == :complete)

    channel = Repo.get_by!(Conversation, id: entry.conversation_id)

    assert {:ok, %{signal: signal}} =
             InboundBatches.finalize_inbound_batch_by_id(result.inbound_batch.id,
               now: DateTime.add(result.inbound_batch.available_at, 1, :second)
             )

    for facts <- [
          entry.raw_payload,
          entry.attachments,
          channel.raw_payload,
          Ankole.Signals.Signal.envelope(signal)
        ],
        value <- forbidden do
      refute String.contains?(Ankole.JSON.encode!(facts), value)
    end
  end
end
