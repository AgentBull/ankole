defmodule Ankole.Plugins.DingTalkAdapterAICardTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.DingTalkAdapter
  alias Ankole.Plugins.DingTalkAdapter.AICard
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias DingTalkOpenAPI.Client

  defp setup_binding(chat_config) do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = AppConfigure.register_patterns(DingTalkAdapter.app_config_patterns())

    config_id = "dingtalk-aicard-#{System.unique_integer([:positive])}"

    {:ok, _config} =
      AppConfigure.put_global_by_key(Config.chat_config_key(config_id), chat_config)

    %{principal: agent} = agent_fixture()

    {:ok, _binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "dingtalk-aicard",
        adapter: "dingtalk",
        config_ref: "app-config://#{Config.chat_config_key(config_id)}",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        "dingtalk-aicard",
        group_entry(%{
          source_event_id: unique_uid("dingtalk-event"),
          source_entry_id: unique_uid("dingtalk-trigger"),
          explicit: true
        })
      )

    event
  end

  # Records every non-token API call to the test process. `fail` maps a request
  # path to `{status, body}` for deterministic provider rejections.
  defp recording_client(parent, fail \\ %{}) do
    Client.new(
      client_id: "cli_aicard",
      client_secret: "secret",
      req_options: [
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          cond do
            conn.request_path == "/v1.0/oauth2/accessToken" ->
              Req.Test.json(conn, %{"accessToken" => "app-tok", "expireIn" => 7200})

            failure = Map.get(fail, conn.request_path) ->
              {status, failure_body} = failure
              send(parent, {:card_call, conn.method, conn.request_path, Torque.decode!(body)})

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(status, Torque.encode!(failure_body))

            true ->
              send(parent, {:card_call, conn.method, conn.request_path, Torque.decode!(body)})

              Req.Test.json(conn, %{
                "success" => true,
                "result" => %{},
                "processQueryKey" => "pqk-#{System.unique_integer([:positive])}"
              })
          end
        end
      ]
    )
  end

  defp working(answer) do
    ReplyPresentation.new() |> ReplyPresentation.append_answer(answer)
  end

  defp completed(answer) do
    ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
  end

  defp fresh(event), do: Repo.get!(ActorEvent, event.id)

  test "open creates+delivers, streams the answer open, and checkpoints the presentation" do
    event =
      setup_binding(%{
        "clientId" => "cli_aicard",
        "clientSecret" => "secret",
        "cardTemplateId" => "tpl-1"
      })

    client = recording_client(self())
    presentation = working("hello from the agent")

    assert {:ok, open_result} =
             AICard.open(%Request{actor_event: event, presentation: presentation, mode: :working},
               client: client
             )

    assert_receive {:card_call, "POST", "/v1.0/card/instances/createAndDeliver", create_body}
    assert create_body["cardTemplateId"] == "tpl-1"
    assert create_body["callbackType"] == "STREAM"
    assert create_body["outTrackId"] == "ankole:#{event.id}:0"
    assert create_body["openSpaceId"] =~ "dtv1.card//IM_GROUP."

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", stream_body}
    assert stream_body["key"] == "answer"
    assert stream_body["isFull"] == true
    assert stream_body["isFinalize"] == false
    assert stream_body["content"] == "hello from the agent"

    checkpoint = open_result.reply_preview_checkpoint
    assert checkpoint["streaming_state"] == "open"
    assert checkpoint["presentation"]["answer"] == "hello from the agent"
    assert [%{"index" => 0, "sealed" => false}] = checkpoint["pages"]

    persisted = fresh(event)
    assert persisted.reply_preview_checkpoint["streaming_state"] == "open"
    assert persisted.reply_preview_checkpoint["presentation"]["answer"] == "hello from the agent"
  end

  test "finalize seals the tail with isFinalize and writes only the tail slice terminally" do
    event =
      setup_binding(%{
        "clientId" => "cli_aicard",
        "clientSecret" => "secret",
        "cardTemplateId" => "tpl-1"
      })

    client = recording_client(self())

    assert {:ok, _open} =
             AICard.open(
               %Request{actor_event: event, presentation: working("short"), mode: :working},
               client: client
             )

    assert_receive {:card_call, "POST", "/v1.0/card/instances/createAndDeliver", _create}
    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", _open_stream}

    assert {:ok, final_result} =
             AICard.finalize(
               %Request{
                 actor_event: fresh(event),
                 presentation: completed("short"),
                 mode: :terminal
               },
               client: client
             )

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", finalize_stream}
    assert finalize_stream["isFinalize"] == true
    assert finalize_stream["isError"] == false

    assert_receive {:card_call, "PUT", "/v1.0/card/instances", terminal_body}
    assert terminal_body["outTrackId"] == "ankole:#{event.id}:0"
    assert get_in(terminal_body, ["cardData", "cardParamMap", "answer"]) == "short"
    assert get_in(terminal_body, ["cardData", "cardParamMap", "thought"]) == ""

    refute_received {:card_call, "POST", "/v1.0/card/instances/createAndDeliver", _}
    assert final_result.reply_preview_checkpoint["streaming_state"] == "closed"
  end

  test "growth rolls onto a continuation card, seals the first page once, and never rewrites it" do
    event =
      setup_binding(%{
        "clientId" => "cli_aicard",
        "clientSecret" => "secret",
        "cardTemplateId" => "tpl-1"
      })

    client = recording_client(self())
    page_one = String.duplicate("A", 2_000)

    assert {:ok, _open} =
             AICard.open(
               %Request{actor_event: event, presentation: working(page_one), mode: :working},
               client: client
             )

    assert_receive {:card_call, "POST", "/v1.0/card/instances/createAndDeliver",
                    %{"outTrackId" => otid0}}

    assert String.ends_with?(otid0, ":0")
    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", %{"outTrackId" => ^otid0}}

    # Growth past the page budget: page 0 seals, page 1 is created and streamed.
    grown = page_one <> "\n" <> String.duplicate("B", 2_000)

    assert {:ok, _update} =
             AICard.update(
               %Request{actor_event: fresh(event), presentation: working(grown), mode: :working},
               client: client
             )

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming",
                    %{"outTrackId" => ^otid0, "isFinalize" => true}}

    assert_receive {:card_call, "POST", "/v1.0/card/instances/createAndDeliver",
                    %{"outTrackId" => otid1}}

    assert String.ends_with?(otid1, ":1")

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming",
                    %{"outTrackId" => ^otid1} = tail_stream}

    assert tail_stream["isFinalize"] == false

    # Further growth touches only the unsealed tail: the sealed page gets no
    # create, stream, or terminal write of any kind.
    grown_more = grown <> " and more"

    assert {:ok, update_result} =
             AICard.update(
               %Request{
                 actor_event: fresh(event),
                 presentation: working(grown_more),
                 mode: :working
               },
               client: client
             )

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming",
                    %{"outTrackId" => ^otid1} = tail_again}

    assert String.ends_with?(tail_again["content"], "and more")
    refute_received {:card_call, _method, _path, %{"outTrackId" => ^otid0}}

    pages = update_result.reply_preview_checkpoint["pages"]
    assert [%{"sealed" => true}, %{"sealed" => false}] = pages
    assert Enum.map_join(pages, "", & &1["source"]) == grown_more
  end

  test "a failed turn finalizes the tail with isError" do
    event =
      setup_binding(%{
        "clientId" => "cli_aicard",
        "clientSecret" => "secret",
        "cardTemplateId" => "tpl-1"
      })

    client = recording_client(self())

    failed =
      ReplyPresentation.new() |> ReplyPresentation.terminal("failed", "it broke")

    assert {:ok, _result} =
             AICard.finalize(
               %Request{actor_event: event, presentation: failed, mode: :terminal},
               client: client
             )

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", stream_body}
    assert stream_body["isFinalize"] == true
    assert stream_body["isError"] == true

    assert_receive {:card_call, "PUT", "/v1.0/card/instances", terminal_body}
    assert get_in(terminal_body, ["cardData", "cardParamMap", "state"]) == "出错"
  end

  test "awaiting_input finalizes without sealing and renders protocol-carrying actions" do
    event =
      setup_binding(%{
        "clientId" => "cli_aicard",
        "clientSecret" => "secret",
        "cardTemplateId" => "tpl-1"
      })

    client = recording_client(self())

    presentation =
      ReplyPresentation.new(state: "awaiting_input")
      |> ReplyPresentation.replace_answer("Which one?")
      |> ReplyPresentation.apply_event("interaction.request", %{
        "operation_id" => "clarify-1",
        "revision" => 7,
        "prompt" => "Which one?",
        "controls" => [
          %{
            "id" => "opt-a",
            "type" => "button",
            "label" => "Option A",
            "source_actor_event_id" => event.id,
            "interaction_id" => "int-1",
            "control_id" => "choice",
            "selected_option_id" => "opt-a",
            "option_value" => "a",
            "revision" => 7
          }
        ]
      })

    assert {:ok, _result} =
             AICard.finalize(
               %Request{actor_event: event, presentation: presentation, mode: :terminal},
               client: client
             )

    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", stream_body}
    assert stream_body["isFinalize"] == false

    assert_receive {:card_call, "PUT", "/v1.0/card/instances", terminal_body}
    actions_json = get_in(terminal_body, ["cardData", "cardParamMap", "actions"])
    assert [action] = Torque.decode!(actions_json)
    assert action["label"] == "Option A"

    assert action["value"] == %{
             "version" => "ankole.interactive_output.action.v1",
             "answerKind" => "choice",
             "interactionId" => "int-1",
             "interactionVersion" => 7,
             "controlId" => "choice",
             "selectedOptionId" => "opt-a",
             "optionValue" => "a",
             "sourceActorEventId" => event.id
           }
  end

  test "with no card template a working sync sends nothing and returns non-retryable" do
    event = setup_binding(%{"clientId" => "cli_aicard", "clientSecret" => "secret"})
    client = recording_client(self())

    assert {:error, {:cardkit_plain_text_fallback, :card_template_missing}} =
             AICard.update(
               %Request{actor_event: event, presentation: working("partial"), mode: :working},
               client: client
             )

    refute_received {:card_call, _method, _path, _body}
  end

  test "with no card template the terminal reply degrades once to ledgered plain chunks" do
    event = setup_binding(%{"clientId" => "cli_aicard", "clientSecret" => "secret"})
    client = recording_client(self())

    long_answer =
      Enum.map_join(1..40, "\n", fn index ->
        "paragraph #{index} " <> String.duplicate("x", 300)
      end)

    assert byte_size(long_answer) > 10_000

    assert {:ok, result} =
             AICard.finalize(
               %Request{
                 actor_event: event,
                 presentation: completed(long_answer),
                 mode: :terminal
               },
               client: client
             )

    assert result.delivered_operation == :post
    assert_receive {:card_call, "POST", "/v1.0/robot/groupMessages/send", first_chunk}
    assert first_chunk["msgKey"] == "sampleText"
    assert_receive {:card_call, "POST", "/v1.0/robot/groupMessages/send", _second_chunk}
    refute_received {:card_call, _method, _path, _body}

    checkpoint = result.reply_preview_checkpoint
    assert checkpoint["degraded"] == true
    assert length(checkpoint["plain_chunks"]) == 2

    # An outbox retry re-runs finalize; the chunk ledger absorbs it without a
    # single provider re-send.
    assert {:ok, _retry} =
             AICard.finalize(
               %Request{
                 actor_event: fresh(event),
                 presentation: completed(long_answer),
                 mode: :terminal
               },
               client: client
             )

    refute_received {:card_call, "POST", "/v1.0/robot/groupMessages/send", _body}
  end

  test "a permanent content rejection degrades once and never oscillates back to cards" do
    event =
      setup_binding(%{
        "clientId" => "cli_aicard",
        "clientSecret" => "secret",
        "cardTemplateId" => "tpl-1"
      })

    rejecting =
      recording_client(self(), %{
        "/v1.0/card/streaming" => {400, %{"code" => "param.contentUnsafe", "message" => "no"}}
      })

    assert {:error, {:cardkit_plain_text_fallback, :content_rejected}} =
             AICard.update(
               %Request{actor_event: event, presentation: working("bad text"), mode: :working},
               client: rejecting
             )

    assert fresh(event).reply_preview_checkpoint["degraded"] == true

    # The rejected attempt itself created the card and hit the streaming wall.
    assert_receive {:card_call, "POST", "/v1.0/card/instances/createAndDeliver", _create}
    assert_receive {:card_call, "PUT", "/v1.0/card/streaming", _rejected_stream}
    refute_received {:card_call, _method, _path, _body}

    # The terminal path never retries the doomed card; it delivers plain text.
    clean = recording_client(self())

    assert {:ok, result} =
             AICard.finalize(
               %Request{
                 actor_event: fresh(event),
                 presentation: completed("bad text"),
                 mode: :terminal
               },
               client: clean
             )

    assert result.delivered_operation == :post
    assert_receive {:card_call, "POST", "/v1.0/robot/groupMessages/send", body}
    assert body["msgParam"] =~ "bad text"

    refute_received {:card_call, _method, "/v1.0/card/streaming", _body}
    refute_received {:card_call, _method, "/v1.0/card/instances", _body}
  end
end
