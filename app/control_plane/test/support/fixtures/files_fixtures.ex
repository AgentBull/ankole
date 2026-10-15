defmodule Ankole.FilesFixtures do
  @moduledoc """
  Test helpers for the `Ankole.Files` context.
  """

  import ExUnit.Assertions

  alias Ankole.Files

  @doc "Stores `content` and names it at `path` in the Agent's drive."
  def drive_file_fixture(agent_uid, path, content \\ "console.log('ok')\n", source \\ "agent") do
    {:ok, %{sha256: sha256}} = Files.store(content)

    {:ok, %{files: [file]}} =
      Files.commit(agent_uid, [%{path: path, sha256: sha256, source: source}])

    file
  end

  @doc """
  Puts `content` in the Agent's drive under `sent/`, as `reply_attachment`
  does, and returns the canonical reply attachment that names it.
  """
  def sent_attachment_fixture(agent_uid, name, content, mime_type) do
    {:ok, %{sha256: sha256}} = Files.store(content)
    path = Files.content_path("sent", sha256, name)

    {:ok, %{files: [file]}} =
      Files.commit(agent_uid, [%{path: path, sha256: sha256, source: "sent"}])

    %{
      "path" => path,
      "blob_ref" => sha256,
      "name" => name,
      "mime_type" => mime_type,
      "size" => file.size
    }
  end

  @doc """
  Asserts that an inbound attachment names its stored bytes in the Agent's
  drive at `chats/<channel>/inbox/<digest prefix>/<file name>`.
  """
  def assert_stored_attachment!(agent_uid, channel_id, attachment, content, file_name) do
    blob_ref = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    path = Files.chat_path(channel_id, Files.content_path("inbox", blob_ref, file_name))

    assert %{"blob_ref" => ^blob_ref, "path" => ^path} = attachment
    assert attachment["size"] == byte_size(content)
    assert {:ok, ^content} = Files.read_content(blob_ref)

    assert {:ok, %{source: "inbound", conversation_id: ^channel_id}, ^content} =
             Files.read(agent_uid, path)
  end
end
