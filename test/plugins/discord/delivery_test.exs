defmodule Discord.DeliveryTest do
  use ExUnit.Case, async: true

  alias BullX.Gateway.Delivery, as: GatewayDelivery
  alias Discord.{Delivery, Source}

  defmodule FakeMessageApi do
    def create(_channel_id, options) do
      send(self(), {:create, options})

      {:ok,
       %{
         "id" =>
           cond do
             options[:message_reference] -> "10"
             true -> "20"
           end
       }}
    end

    def edit(_channel_id, message_id, options) do
      send(self(), {:edit, message_id, options})
      {:ok, %{"id" => to_string(message_id)}}
    end

    def delete(_channel_id, _message_id), do: :ok
  end

  defmodule FailingMessageApi do
    def create(_channel_id, _options) do
      {:error,
       %{__exception__: true, __struct__: Nostrum.Error.ApiError, status_code: 404, response: %{}}}
    end
  end

  defp source(api \\ FakeMessageApi) do
    %Source{
      adapter: "discord",
      channel_id: "main",
      application_id: "111",
      bot_token: "tok",
      bot_user_id: "9999",
      stream_chunk_soft_limit: 2_000,
      message_api: api,
      start_transport?: false
    }
  end

  defp delivery(opts \\ []) do
    %GatewayDelivery{
      id: BullX.Ext.gen_uuid_v7(),
      generation: 0,
      op: Keyword.get(opts, :op, :send),
      adapter: "discord",
      channel_id: "main",
      scope_id: Keyword.get(opts, :scope_id, "100"),
      thread_id: nil,
      reply_to_external_id: Keyword.get(opts, :reply_to_external_id),
      target_external_id: Keyword.get(opts, :target_external_id),
      content: [%{"kind" => "text", "body" => %{"text" => Keyword.get(opts, :text, "hello")}}],
      extensions: %{}
    }
  end

  test "send delivers single text chunk with safe allowed_mentions" do
    {:ok, outcome} = Delivery.deliver(delivery(), source())

    assert_received {:create, options}
    assert options[:content] == "hello"
    assert options[:allowed_mentions] == %{"parse" => ["users"], "replied_user" => true}
    refute Map.has_key?(options, :message_reference)
    assert outcome["status"] == "sent"
  end

  test "send with reply_to_external_id sets message_reference" do
    {:ok, _outcome} =
      Delivery.deliver(delivery(reply_to_external_id: "ref_1"), source())

    assert_received {:create, options}
    assert options[:message_reference] == %{message_id: "ref_1", fail_if_not_exists: false}
  end

  test "send retries without reply_reference on reply-target missing" do
    defmodule Flaky do
      def create(_channel_id, options) do
        if options[:message_reference] do
          {:error,
           %{
             __exception__: true,
             __struct__: Nostrum.Error.ApiError,
             status_code: 404,
             response: %{}
           }}
        else
          {:ok, %{"id" => "fallback_msg"}}
        end
      end
    end

    {:ok, outcome} =
      Delivery.deliver(delivery(reply_to_external_id: "ghost"), source(Flaky))

    assert outcome["status"] == "degraded"
    assert "reply_target_missing_sent_to_scope" in outcome["warnings"]
    assert outcome["primary_external_id"] == "fallback_msg"
  end

  test "edit calls edit api" do
    {:ok, _outcome} =
      Delivery.deliver(delivery(op: :edit, target_external_id: "target"), source())

    assert_received {:edit, _message_id, options}
    assert options[:content] == "hello"
    assert options[:allowed_mentions] == %{"parse" => ["users"], "replied_user" => true}
  end

  test "edit without target_external_id returns payload error" do
    {:error, error} = Delivery.deliver(delivery(op: :edit), source())
    assert error["kind"] == "payload"
  end

  test "send_text splits long text into multiple messages with first reply only" do
    long_text = String.duplicate("a", 50)

    delivery = %{
      delivery(reply_to_external_id: "ref")
      | content: [%{"kind" => "text", "body" => %{"text" => long_text}}]
    }

    # Use a very small soft limit to force splitting
    source = %{source() | stream_chunk_soft_limit: 10}

    {:ok, outcome} = Delivery.send_text(delivery, long_text, source)
    assert length(outcome["external_message_ids"]) > 1
    assert outcome["status"] in ["sent", "degraded"]
  end
end
