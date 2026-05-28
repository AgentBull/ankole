defmodule Feishu.StreamingCardTest do
  use ExUnit.Case, async: false

  alias Feishu.{Source, StreamingCard}
  alias FeishuOpenAPI.{Client, TokenManager}

  defmodule StreamingOutput do
    def resume_stream(stream_id, nil) do
      send(test_pid(stream_id), {:resume_after_offset, nil})

      {:ok,
       %{
         status: :open,
         chunks: [%{offset: 0, chunk: "hello"}],
         follow?: true
       }}
    end

    def follow_stream(stream_id, after_offset, consumer) do
      send(test_pid(stream_id), {:follow_after_offset, after_offset})
      consumer.(%{type: :chunk, offset: 1, chunk: " world"})
      consumer.(%{type: :terminal, status: :completed})
      :ok
    end

    defp test_pid(stream_id), do: :persistent_term.get({__MODULE__, stream_id})
  end

  defmodule CompletedStreamingOutput do
    def resume_stream(stream_id, nil) do
      send(test_pid(stream_id), {:completed_resume_after_offset, nil})

      {:ok,
       %{
         status: :completed,
         chunks: [%{offset: 0, chunk: "hello"}],
         follow?: false
       }}
    end

    defp test_pid(stream_id), do: :persistent_term.get({__MODULE__, stream_id})
  end

  defmodule EmptyCompletedStreamingOutput do
    def resume_stream(stream_id, nil) do
      send(test_pid(stream_id), {:empty_completed_resume_after_offset, nil})

      {:ok, %{status: :completed, chunks: [], follow?: false}}
    end

    defp test_pid(stream_id), do: :persistent_term.get({__MODULE__, stream_id})
  end

  test "follows an open stream after the last resumed offset" do
    stream_id = "stream_follow_offset"
    :persistent_term.put({StreamingOutput, stream_id}, self())
    on_exit(fn -> :persistent_term.erase({StreamingOutput, stream_id}) end)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token",
            "expire" => 7200
          })

        "/open-apis/cardkit/v1/cards" ->
          send(parent, {:card_create_body, conn.body_params})
          Req.Test.json(conn, %{"code" => 0, "data" => %{"card_id" => "card_1"}})
      end
    end)

    app_id = "cli_stream_" <> Integer.to_string(:erlang.unique_integer([:positive]))

    client =
      Client.new(app_id, "secret_x", req_options: [plug: {Req.Test, __MODULE__}])

    {:ok, manager_pid} =
      DynamicSupervisor.start_child(FeishuOpenAPI.TokenManager.Supervisor, {TokenManager, client})

    Req.Test.allow(__MODULE__, self(), manager_pid)

    source = %Source{
      id: "main",
      app_id: app_id,
      app_secret: "secret_x",
      client: client,
      stream_update_interval_ms: 1_000
    }

    reply_address = %{"scope_id" => "oc_chat"}

    delivery_fun = fn delivery, _source, _opts ->
      refute delivery["id"] == stream_id

      assert delivery["id"] =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      {:ok, %{"status" => "sent", "primary_external_id" => "om_card", "warnings" => []}}
    end

    delivery_update_fun = fn result ->
      send(parent, {:delivery_update, result})
      :ok
    end

    update_fun = fn source, card_id, text, sequence ->
      send(parent, {:card_update, source.id, card_id, text, sequence})
      :ok
    end

    replace_fun = fn source, card_id, text, sequence ->
      send(parent, {:card_replace, source.id, card_id, text, sequence})
      :ok
    end

    finalize_fun = fn source, card_id, text, sequence ->
      send(parent, {:card_finalize, source.id, card_id, text, sequence})
      :ok
    end

    assert :ok =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn ->
               StreamingCard.consume(source, reply_address, stream_id,
                 streaming_output: StreamingOutput,
                 delivery_fun: delivery_fun,
                 delivery_update_fun: delivery_update_fun,
                 card_update_fun: update_fun,
                 card_replace_content_fun: replace_fun,
                 card_finalize_fun: finalize_fun
               )
             end)

    assert_received {:delivery_update,
                     %{
                       "status" => "sent",
                       "primary_external_id" => "om_card",
                       "external_message_ids" => ["om_card"],
                       "card_id" => "card_1"
                     }}

    assert_received {:card_create_body,
                     %{
                       "type" => "card_json",
                       "data" => encoded_card
                     }}

    assert %{
             "config" => %{
               "update_multi" => true,
               "streaming_mode" => true,
               "summary" => %{"content" => "正在思考..."}
             },
             "body" => %{
               "padding" => "12px 12px 12px 12px",
               "elements" => [
                 %{
                   "tag" => "div",
                   "text" => %{
                     "tag" => "plain_text",
                     "content" => "正在思考...",
                     "text_size" => "notation",
                     "text_align" => "left",
                     "text_color" => "grey"
                   },
                   "icon" => %{
                     "tag" => "standard_icon",
                     "token" => "ai-common_colorful",
                     "color" => "grey"
                   },
                   "margin" => "0px 0px 0px 0px",
                   "element_id" => "content"
                 }
               ]
             }
           } = Jason.decode!(encoded_card)

    assert_received {:resume_after_offset, nil}
    assert_received {:follow_after_offset, 0}
    assert_received {:card_replace, "main", "card_1", "hello", 1}
    assert_received {:card_update, "main", "card_1", "hello world", 2}
    assert_received {:card_finalize, "main", "card_1", "hello world", 3}
  end

  test "replaces the thinking element with a markdown streaming element on first output" do
    stream_id = "stream_replace_thinking"
    :persistent_term.put({CompletedStreamingOutput, stream_id}, self())
    on_exit(fn -> :persistent_term.erase({CompletedStreamingOutput, stream_id}) end)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token",
            "expire" => 7200
          })

        "/open-apis/cardkit/v1/cards" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"card_id" => "card_1"}})

        "/open-apis/cardkit/v1/cards/card_1/elements/content" ->
          send(parent, {:replace_body, conn.body_params})
          Req.Test.json(conn, %{"code" => 0})

        "/open-apis/cardkit/v1/cards/card_1/elements/content/content" ->
          send(parent, {:content_body, conn.body_params})
          Req.Test.json(conn, %{"code" => 0})

        "/open-apis/cardkit/v1/cards/card_1/settings" ->
          send(parent, {:settings_body, conn.body_params})
          Req.Test.json(conn, %{"code" => 0})
      end
    end)

    app_id = "cli_stream_" <> Integer.to_string(:erlang.unique_integer([:positive]))

    client =
      Client.new(app_id, "secret_x", req_options: [plug: {Req.Test, __MODULE__}])

    {:ok, manager_pid} =
      DynamicSupervisor.start_child(FeishuOpenAPI.TokenManager.Supervisor, {TokenManager, client})

    Req.Test.allow(__MODULE__, self(), manager_pid)

    source = %Source{
      id: "main",
      app_id: app_id,
      app_secret: "secret_x",
      client: client,
      stream_update_interval_ms: 1_000
    }

    delivery_fun = fn _delivery, _source, _opts ->
      {:ok, %{"status" => "sent", "primary_external_id" => "om_card", "warnings" => []}}
    end

    assert :ok =
             StreamingCard.consume(source, %{"scope_id" => "oc_chat"}, stream_id,
               streaming_output: CompletedStreamingOutput,
               delivery_fun: delivery_fun
             )

    assert_received {:completed_resume_after_offset, nil}

    assert_received {:replace_body, %{"element" => encoded_element, "sequence" => 1}}

    assert %{
             "tag" => "markdown",
             "content" => "hello",
             "element_id" => "content"
           } = Jason.decode!(encoded_element)

    assert_received {:content_body, %{"content" => "hello", "sequence" => 2}}
    assert_received {:settings_body, %{"sequence" => 3}}
  end

  test "completed empty streams do not finalize as thinking" do
    stream_id = "stream_completed_empty"
    :persistent_term.put({EmptyCompletedStreamingOutput, stream_id}, self())
    on_exit(fn -> :persistent_term.erase({EmptyCompletedStreamingOutput, stream_id}) end)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token",
            "expire" => 7200
          })

        "/open-apis/cardkit/v1/cards" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"card_id" => "card_1"}})

        "/open-apis/cardkit/v1/cards/card_1/elements/content" ->
          send(parent, {:empty_replace_body, conn.body_params})
          Req.Test.json(conn, %{"code" => 0})

        "/open-apis/cardkit/v1/cards/card_1/settings" ->
          send(parent, {:empty_settings_body, conn.body_params})
          Req.Test.json(conn, %{"code" => 0})
      end
    end)

    app_id = "cli_stream_" <> Integer.to_string(:erlang.unique_integer([:positive]))
    client = Client.new(app_id, "secret_x", req_options: [plug: {Req.Test, __MODULE__}])

    {:ok, manager_pid} =
      DynamicSupervisor.start_child(FeishuOpenAPI.TokenManager.Supervisor, {TokenManager, client})

    Req.Test.allow(__MODULE__, self(), manager_pid)

    source = %Source{
      id: "main",
      app_id: app_id,
      app_secret: "secret_x",
      client: client,
      stream_update_interval_ms: 1_000
    }

    delivery_fun = fn _delivery, _source, _opts ->
      {:ok, %{"status" => "sent", "primary_external_id" => "om_card", "warnings" => []}}
    end

    assert :ok =
             BullX.I18n.with_locale(:"zh-Hans-CN", fn ->
               StreamingCard.consume(source, %{"scope_id" => "oc_chat"}, stream_id,
                 streaming_output: EmptyCompletedStreamingOutput,
                 delivery_fun: delivery_fun
               )
             end)

    assert_received {:empty_completed_resume_after_offset, nil}
    assert_received {:empty_replace_body, %{"element" => encoded_element, "sequence" => 1}}
    assert %{"content" => "已完成，但没有生成可显示内容。"} = Jason.decode!(encoded_element)
    assert_received {:empty_settings_body, %{"sequence" => 2}}
  end
end
