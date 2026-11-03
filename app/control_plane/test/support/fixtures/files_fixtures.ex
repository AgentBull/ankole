defmodule Ankole.FilesFixtures do
  @moduledoc "Test helpers for immutable Drive objects and their node references."
  import ExUnit.Assertions
  alias Ankole.Files

  def publish_applet_fixture(%{actor: actor, page: page}, source, revision \\ 0) do
    manifest = applet_manifest_fixture(actor.principal.uid, page.id, source)
    assert {:ok, result} = Ankole.Pod.Files.publish(actor, page.id, revision, manifest)
    result
  end

  def applet_manifest_fixture(uid, page_id, source) do
    for {path, bytes} <- [
          {"src/main.tsx", "source"},
          {"dist/index.html", "<html/>"},
          {"server/main.js", source}
        ] do
      source_path = "publish/#{page_id}/#{path}"
      file = drive_file_fixture(uid, source_path, bytes)
      %{path: path, object_id: file.object_id, source_path: source_path}
    end
  end

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
    assert {:ok, ^conversation_id} = Ankole.Pod.node_conversation_id(node_id)

    assert {:ok, %{source: "inbound", name: ^file_name, object_id: ^object_id}} =
             Ankole.Pod.fetch_node(node_id)
  end
end
