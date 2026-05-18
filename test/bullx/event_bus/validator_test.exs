defmodule BullX.EventBus.ValidatorTest do
  use ExUnit.Case, async: true

  alias BullX.EventBus.{InvalidEvent, Validator}

  test "rejects atom-keyed maps" do
    assert {:error, %InvalidEvent{code: :not_json_neutral}} =
             Validator.validate(%{specversion: "1.0"})
  end

  test "rejects NUL-containing strings before PostgreSQL jsonb handoff" do
    event =
      valid_event() |> put_in(["data", "content", Access.at(0), "body", "text"], "bad" <> <<0>>)

    assert {:error,
            %InvalidEvent{code: :nul_string, path: ["data", "content", 0, "body", "text"]}} =
             Validator.validate(event)
  end

  test "rejects routing_facts keys that are not path safe" do
    event = valid_event() |> put_in(["data", "routing_facts"], %{"Provider Event" => "x"})

    assert {:error, %InvalidEvent{code: :invalid_payload_shape}} = Validator.validate(event)
  end

  test "rejects raw_ref values that inline payload instead of a reference" do
    event = valid_event() |> put_in(["data", "raw_ref"], %{"payload" => %{"text" => "raw"}})

    assert {:error, %InvalidEvent{code: :invalid_payload_shape, path: ["data", "raw_ref"]}} =
             Validator.validate(event)
  end

  defp valid_event do
    %{
      "specversion" => "1.0",
      "id" => "event-1",
      "source" => "feishu://connected-realm/default",
      "type" => "bullx.im.message.addressed",
      "time" => "2026-05-17T10:00:00Z",
      "datacontenttype" => "application/json",
      "data" => %{
        "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}],
        "channel" => %{"adapter" => "feishu", "id" => "default"},
        "scope" => %{"id" => "chat-1", "thread_id" => nil},
        "actor" => %{"id" => "user-1", "display" => nil, "bot" => false, "principal_ref" => nil},
        "refs" => [],
        "reply_channel" => nil,
        "routing_facts" => %{},
        "raw_ref" => nil
      }
    }
  end
end
