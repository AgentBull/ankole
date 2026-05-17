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

  test "follows an open stream after the last resumed offset" do
    stream_id = "stream_follow_offset"
    :persistent_term.put({StreamingOutput, stream_id}, self())
    on_exit(fn -> :persistent_term.erase({StreamingOutput, stream_id}) end)

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

    reply_channel = %{"scope_id" => "oc_chat"}

    delivery_fun = fn delivery, _source, _opts ->
      assert delivery["id"] == stream_id
      {:ok, %{"status" => "sent", "primary_external_id" => "om_card", "warnings" => []}}
    end

    parent = self()

    update_fun = fn source, card_id, text, sequence ->
      send(parent, {:card_update, source.id, card_id, text, sequence})
      :ok
    end

    finalize_fun = fn source, card_id, text, sequence ->
      send(parent, {:card_finalize, source.id, card_id, text, sequence})
      :ok
    end

    assert :ok =
             StreamingCard.consume(source, reply_channel, stream_id,
               streaming_output: StreamingOutput,
               delivery_fun: delivery_fun,
               card_update_fun: update_fun,
               card_finalize_fun: finalize_fun
             )

    assert_received {:resume_after_offset, nil}
    assert_received {:follow_after_offset, 0}
    assert_received {:card_update, "main", "card_1", "hello", 1}
    assert_received {:card_finalize, "main", "card_1", "hello world", 2}
  end
end
