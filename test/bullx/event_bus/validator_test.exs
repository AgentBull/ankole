defmodule BullX.EventBus.ValidatorTest do
  use ExUnit.Case, async: true

  alias BullX.EventBus.{InvalidEvent, Validator}

  test "rejects atom-keyed maps" do
    assert {:error, %InvalidEvent{code: :not_json_neutral}} =
             Validator.validate(%{specversion: "1.0"})
  end

  test "rejects NUL-containing strings before PostgreSQL jsonb handoff" do
    event =
      valid_event() |> put_in(["data", "content", Access.at(0), "text"], "bad" <> <<0>>)

    assert {:error, %InvalidEvent{code: :nul_string, path: ["data", "content", 0, "text"]}} =
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

  test "rejects actor fields outside the normalized contract" do
    event = valid_event() |> put_in(["data", "actor", "profile"], %{"open_id" => "ou_1"})

    assert {:error, %InvalidEvent{code: :invalid_payload_shape, path: ["data", "actor"]}} =
             Validator.validate(event)
  end

  test "rejects card content without fallback text" do
    event =
      valid_event()
      |> put_in(["data", "content"], [
        %{"type" => "card", "format" => "feishu.card", "payload" => %{}}
      ])

    assert {:error, %InvalidEvent{code: :invalid_payload_shape, path: ["data", "content", 0]}} =
             Validator.validate(event)
  end

  test "rejects action content without transcript text" do
    event =
      valid_event()
      |> put_in(["data", "content"], [%{"type" => "action", "action_id" => "approve"}])

    assert {:error, %InvalidEvent{code: :invalid_payload_shape, path: ["data", "content", 0]}} =
             Validator.validate(event)
  end

  test "rejects non-null reply_channel without delivery identity" do
    event = valid_event() |> put_in(["data", "reply_channel"], %{})

    assert {:error, %InvalidEvent{code: :invalid_payload_shape, path: ["data", "reply_channel"]}} =
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
        "content" => [%{"type" => "text", "text" => "hello"}],
        "channel" => %{"adapter" => "feishu", "id" => "default", "kind" => "dm"},
        "scope" => %{"id" => "chat-1", "thread_id" => nil},
        "actor" => %{"external_account_id" => "user-1", "display_name" => nil, "principal" => nil},
        "refs" => [],
        "reply_channel" => nil,
        "routing_facts" => %{},
        "raw_ref" => nil
      }
    }
  end
end
