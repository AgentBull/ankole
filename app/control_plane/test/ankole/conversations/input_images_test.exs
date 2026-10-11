defmodule Ankole.Conversations.InputImagesTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  alias Ankole.Conversations.Prompt.Input
  alias Ankole.Conversations.Worker

  test "received drive images cross the native normalization boundary and invalid images are omitted" do
    %{principal: agent} = agent_fixture()
    bytes = File.read!(Path.expand("../../fixtures/conversations/rgba.png", __DIR__))
    photo = drive_file_fixture(agent.uid, "inbox/photo.png", bytes)
    broken = drive_file_fixture(agent.uid, "inbox/broken.png", "invalid image bytes")

    payload = %{
      "data" => %{
        "entry" => %{
          "text" => "Inspect the photo",
          "attachments" =>
            Enum.map(
              [photo, broken],
              &%{
                "path" => &1.path,
                "blob_ref" => Base.encode16(&1.sha256, case: :lower),
                "resource_type" => "image"
              }
            )
        }
      }
    }

    event = %Ankole.SignalsGateway.ActorEvent{
      id: Ecto.UUID.generate(),
      type: "im.message.addressed",
      payload: payload
    }

    run = %{
      agent_uid: agent.uid,
      actor_event_id: event.id,
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
    png = File.read!(Path.expand("../../fixtures/conversations/rgba.png", __DIR__))

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
