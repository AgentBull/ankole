defmodule Ankole.Sessions.InputImagesTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  alias Ankole.Sessions.Prompt.Input
  alias Ankole.Sessions.Worker

  test "received drive images cross the native normalization boundary and invalid images are omitted" do
    %{principal: agent} = agent_fixture()

    {:ok, room} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_conversation_in_tx(
          %{agent_uid: agent.uid},
          %{
            provider_conversation_id: "test:images",
            external_kind: :im_group,
            title: "Images",
            reply_mode: :entry
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    bytes = File.read!(Path.expand("../../fixtures/sessions/rgba.png", __DIR__))
    photo = drive_file_fixture(agent.uid, "chats/#{room.id}/inbox/photo.png", bytes)

    broken =
      drive_file_fixture(agent.uid, "chats/#{room.id}/inbox/broken.png", "invalid image bytes")

    payload = %{
      "data" => %{
        "entry" => %{
          "text" => "Inspect the photo",
          "attachments" =>
            Enum.map(
              [photo, broken],
              &%{
                "path" => &1.path,
                "object_id" => &1.object_id,
                "node_id" => &1.id,
                "resource_type" => "image"
              }
            )
        }
      }
    }

    {:ok, %{message: message}} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_in_tx(
          room.id,
          %{
            provider_message_id: "image-message",
            text: "Inspect the photo",
            attachments: payload["data"]["entry"]["attachments"],
            author: %{"principal_uid" => agent.uid}
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    event = %Ankole.Signals.Signal{
      producer: :kernel,
      agent_uid: agent.uid,
      conversation_id: room.id,
      message_id: message.id,
      id: Ecto.UUID.generate(),
      type: "conversation.message.addressed",
      source: "test:images",
      occurred_at: DateTime.utc_now(:microsecond),
      data: payload["data"]
    }

    run = %{
      agent_uid: agent.uid,
      signal_id: event.id,
      event: event,
      context: %{conversation: %{timezone: "UTC"}}
    }

    [%{"content" => content}] = Input.messages(run, event)

    assert [%{"image_url" => "data:image/webp;base64," <> encoded}] =
             Enum.filter(content, &(&1["type"] == "input_image"))

    assert <<"RIFF", _size::little-32, "WEBP", _::binary>> = Base.decode64!(encoded)
    assert byte_size(encoded) + byte_size("data:image/webp;base64,") <= 4 * 1024 * 1024
  end

  test "tool result images get the same conversion and follow with the output as caption" do
    png = File.read!(Path.expand("../../fixtures/sessions/rgba.png", __DIR__))

    content = [
      %{"type" => "text", "text" => "Image file: chart.png (image/png)"}
    ]

    assert {:result, "call-1", result, [%{"role" => "user", "content" => parts}]} =
             Worker.decode(:tool_result, tool_result(content, [png, "broken"]))

    assert result.output == "Image file: chart.png (image/png)"

    assert [
             %{"type" => "input_text", "text" => "Image file: chart.png (image/png)"},
             %{"type" => "input_image", "image_url" => "data:image/webp;base64," <> _},
             %{"type" => "input_text", "text" => "[The image could not be decoded.]"}
           ] = parts

    assert {:result, "call-1", _result, []} =
             Worker.decode(:tool_result, tool_result([%{"type" => "text", "text" => "done"}]))
  end

  defp tool_result(content, images \\ []),
    do: %Ankole.RuntimeFabric.V1.ToolResult{
      call_id: "call-1",
      images: images,
      content_json: Ankole.JSON.encode!(content),
      details_json: "{}"
    }
end
