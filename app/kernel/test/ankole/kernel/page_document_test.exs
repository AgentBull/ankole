defmodule Ankole.Kernel.PageDocumentTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel

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
end
