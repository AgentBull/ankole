defmodule Ankole.Files.PathBidiTest do
  use ExUnit.Case, async: true

  alias Ankole.Conversations.Delivery.Attachment
  alias Ankole.Conversations.FactNormalizer
  alias Ankole.Files.Path, as: FilePath
  alias Ankole.Sessions.Prompt.Input
  alias Ankole.Signals.Binding

  test "file_name strips Unicode Bidi overrides while preserving ZWJ composite emoji" do
    assert FilePath.file_name("报价单_\u202Efdp.sh") == "报价单_fdp.sh"
    assert FilePath.file_name("report\u061C\u200E\u200F\u2066\u2069.pdf") == "report.pdf"
    assert FilePath.file_name("研发_👩\u200D💻_报告.pdf") == "研发_👩\u200D💻_报告.pdf"
    assert FilePath.file_name("line\u2028sep\u2029nel\u0085.txt") == "line_sep_nel_.txt"
    assert FilePath.file_name("\u202E..") == "file"
    assert FilePath.file_name(<<"bad", 0xFF, 0xFE, "\u202E.txt">>) == "bad.txt"
    assert FilePath.sanitize_inline_text(<<"ok", 0xFF, "\nnext">>) == "ok next"
    assert FilePath.strip_bidi_and_controls("Hello \u202E\nWorld ") == "Hello World "
    assert FilePath.strip_bidi_and_controls("e\u0301\u202E\n") == "e\u0301"
    assert FilePath.file_name("e\u0301\u202E.txt") == "é.txt"
  end

  test "normalize rejects Bidi and control segments while normalize_existing resolves legacy paths" do
    legacy = "archive/报价单_\u202Efdp.sh"
    assert {:error, {:invalid_path, ^legacy}} = FilePath.normalize(legacy)
    assert {:ok, ^legacy} = FilePath.normalize_existing(legacy)

    for bad <- [
          "bad\u061Cname.txt",
          "bad\u2028name.txt",
          "bad\u0085name.txt",
          "bad\u2066name.txt"
        ] do
      refute FilePath.valid_segment?(bad)
      assert {:error, {:invalid_path, ^bad}} = FilePath.normalize(bad)
    end

    assert FilePath.valid_segment?("研发_👩\u200D💻_报告.pdf")
    assert {:ok, "docs/研发_👩\u200D💻_报告.pdf"} = FilePath.normalize("docs/研发_👩\u200D💻_报告.pdf")
  end

  test "FactNormalizer, Delivery.Attachment, and Prompt.Input sanitize all attachment name and path keys" do
    binding = %Binding{
      agent_uid: "01900000-0000-7000-8000-000000000001",
      name: "lark",
      adapter: "lark"
    }

    now = DateTime.utc_now(:microsecond)

    {:ok, fact} =
      FactNormalizer.entry(
        binding,
        %{
          source_event_id: "evt-1",
          provider_conversation_id: "conv-1",
          provider_message_id: "msg-1",
          attachments: [
            %{
              "provider_file_id" => "file-1",
              "name" => "报价单_\u202Efdp.sh",
              "filename" => "发票_\u2066exe.pdf",
              "file_name" => "合同_\u061Cbat.docx",
              "title" => "附件\u2028标题.txt",
              "path" => "inbox/报价单_\u202Efdp.sh"
            },
            %{
              "provider_file_id" => "file-2",
              "name" => "\n\r",
              "filename" => "\u2028",
              "path" => "\n\r"
            },
            %{
              "provider_file_id" => "file-3",
              "name" => "\u202E\u2066",
              "filename" => "\u061C",
              "path" => "../\u202E"
            }
          ]
        },
        now
      )

    [att, control_only, bidi_only] = fact.attachments
    assert att["name"] == "报价单_fdp.sh"
    assert att["filename"] == "发票_exe.pdf"
    assert att["file_name"] == "合同_bat.docx"
    assert att["title"] == "附件_标题.txt"
    assert att["path"] == "inbox/报价单_fdp.sh"
    assert control_only["name"] == "_"
    assert control_only["filename"] == "_"
    assert control_only["path"] == "_"
    assert bidi_only["name"] == "file"
    assert bidi_only["filename"] == "file"
    assert bidi_only["path"] == "file"

    node_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()

    assert {:ok, normalized} =
             Attachment.normalize_attachment(%{
               "path" => "sent/报价单_\u202Efdp.sh",
               "object_id" => object_id,
               "node_id" => node_id,
               "name" => "报价单_\u202Efdp.sh",
               "size" => 42
             })

    assert normalized["path"] == "sent/报价单_fdp.sh"
    assert normalized["name"] == "报价单_fdp.sh"

    [msg] =
      Input.context_messages([
        %{
          id: Ecto.UUID.generate(),
          conversation_id: Ecto.UUID.generate(),
          seq: 1,
          author_type: "human",
          author_uid: "alice",
          attachments: [
            %{
              "object_id" => object_id,
              "file_name" => "报价单_\u202Efdp.sh",
              "path" => "uploads/报价单_\u202Efdp.sh",
              "size" => 128
            }
          ],
          text: "check this file"
        }
      ])

    [%{"text" => prompt_text}] = msg["content"]
    assert prompt_text =~ "uploads/报价单_fdp.sh"
    refute FilePath.contains_bidi?(prompt_text)
  end
end
