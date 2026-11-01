defmodule Ankole.FilesFixtures do
  @moduledoc "Test helpers for immutable Drive objects and their node references."
  import ExUnit.Assertions
  alias Ankole.Files

  def drive_file_fixture(agent_uid, path, content \\ "console.log('ok')\n", source \\ "agent") do
    {:ok, stored} = Files.store(content)

    {:ok, %{files: [file]}} =
      Files.commit(agent_uid, [Map.merge(stored, %{path: path, source: source})])

    file
  end

  def sent_attachment_fixture(agent_uid, name, content, mime_type) do
    path = "sent/#{Ankole.Ecto.UUIDv7.autogenerate()}/#{Files.file_name(name)}"
    file = drive_file_fixture(agent_uid, path, content, "sent")

    %{
      "node_id" => file.id,
      "object_id" => file.object_id,
      "path" => path,
      "name" => name,
      "mime_type" => mime_type,
      "size" => file.size
    }
  end

  def assert_stored_attachment!(_agent_uid, conversation_id, attachment, content, file_name) do
    assert %{"object_id" => object_id, "node_id" => node_id} = attachment
    assert attachment["size"] == byte_size(content)
    assert {:ok, ^content} = Files.read_object(object_id)
    assert {:ok, ^conversation_id} = Files.node_conversation_id(node_id)

    assert {:ok, %{source: "inbound", name: ^file_name, object_id: ^object_id}} =
             Files.fetch_node(node_id)
  end
end
