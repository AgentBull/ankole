defmodule Ankole.Kernel.PageDocumentTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel

  test "Agent block conversions retain body tokens and current comments across the NIF boundary" do
    id = "019a2b00-0000-7000-8000-000000000001"
    source = ~s(<page><p><comment ids="#{id}">Hello</comment> world</p></page>)
    target = "<page><h2>Hello world</h2></page>"

    assert {:ok, %{xml: restored}} = Kernel.page_restore_comments(source, target)
    assert restored == ~s(<page><h2><comment ids="#{id}">Hello</comment> world</h2></page>)
    assert {:ok, changes} = Kernel.page_diff(source, restored)
    assert changes == [[1, [%{"type" => "Heading", "param" => 2}]], 12]
    assert {:ok, %{xml: ^restored}} = Kernel.page_apply(source, changes)
  end

  test "native comment helpers return attribution, clean snapshots, and current-mark restores" do
    id = "019a2b00-0000-7000-8000-000000000001"
    source = "<page><p>Hello world</p></page>"

    assert {:ok, %{xml: marked, plain_text: "Hello world", quote: "Hello"}} =
             Kernel.page_comment_annotate(source, id, 1, 6)

    assert {:ok, %{ids: [^id], stripped_xml: ^source}} = Kernel.page_comment_info(marked)
    assert {:ok, %{xml: ^source}} = Kernel.page_comment_remove(marked, id)

    assert {:ok, %{xml: restored, plain_text: "Hello team"}} =
             Kernel.page_restore_comments(marked, "<page><p>Hello team</p></page>")

    assert {:ok, %{ids: [^id]}} = Kernel.page_comment_info(restored)
    assert {:error, _} = Kernel.page_comment_annotate(source, "invalid", 1, 6)
  end

  test "page validation derives searchable text across the native boundary" do
    assert {:ok, %{xml: xml, plain_text: "标题\n正文"}} =
             Kernel.page_validate(
               ~s(<page><h1>标题</h1><p><a href="ankole:page/linked">正文</a></p><embed ref="child" /></page>)
             )

    assert xml =~ ~s(<embed ref="child" />)
    assert {:error, reason} = Kernel.page_validate("<page><p><table /></p></page>")
    assert is_binary(reason)
  end

  test "prepared local edits use the same XML conversion on consecutive batches" do
    source = "<page><p>ab</p></page>"
    changes = [2, [0, [%{"type" => "Text", "param" => "中"}]], 2]

    assert {:ok, %{xml: "<page><p>a中b</p></page>" = updated}} =
             Kernel.page_apply(source, changes)

    assert {:ok, %{xml: "<page><p>a中🙂b</p></page>"}} =
             Kernel.page_apply(updated, [3, [0, [%{"type" => "Text", "param" => "🙂"}]], 2])

    assert {:error, _reason} = Kernel.page_apply(updated, [999])
  end

  test "the declared XML depth is safe across the NIF boundary" do
    source =
      "<page>" <>
        String.duplicate("<blockquote>", 128) <>
        String.duplicate("</blockquote>", 128) <> "</page>"

    assert {:ok, %{xml: canonical}} = Kernel.page_validate(source)
    assert {:ok, %{xml: ^canonical}} = Kernel.page_apply(canonical, [256])
  end

  test "page_identity_changes/1 returns the single-retain ChangeSet for normalized pages" do
    assert {:ok, [2]} = Kernel.page_identity_changes("<page />")
    assert {:ok, %{xml: "<page />"}} = Kernel.page_apply("<page />", [2])

    source =
      ~s(<page><h1>标题 🙂</h1><p><strong>正文</strong></p><embed href="https://example.com" /></page>)

    assert {:ok, %{xml: canonical}} = Kernel.page_validate(source)
    assert {:ok, [span] = identity} = Kernel.page_identity_changes(source)
    assert is_integer(span) and span > 2
    assert {:ok, %{xml: ^canonical}} = Kernel.page_apply(source, identity)
  end
end
