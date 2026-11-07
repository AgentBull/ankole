defmodule Ankole.Kernel.KnowledgeTest do
  use ExUnit.Case, async: true
  alias Ankole.Kernel

  test "knowledge metadata and body cross the NIF boundary without losing structure" do
    source =
      "---\ntags: [guide, 中文]\ncustom:\n  enabled: true\n---\n\n# Title\n\nIntro @alice.\n\n## Details\n\nBody"

    assert {:ok, page} = Kernel.knowledge_parse(source)
    assert page.metadata == %{"tags" => ["guide", "中文"], "custom" => %{"enabled" => true}}
    assert page.xml =~ ~s(<mention principal="alice" />.)
    assert {:ok, validated} = Kernel.knowledge_validate(page.xml)
    assert validated.xml == page.xml
    assert {:ok, exported} = Kernel.knowledge_export(page.xml, page.metadata)
    assert {:ok, ^page} = Kernel.knowledge_parse(exported)
    assert {:ok, overview} = Kernel.knowledge_overview(page.xml, page.metadata)
    assert overview =~ "## Details"
    refute overview =~ "Body"
    refute overview =~ "custom:"
  end

  test "knowledge rejects document-only blocks at the native boundary" do
    assert {:error, reason} =
             Kernel.knowledge_validate(
               "<page><infographic>infographic list-row-simple-horizontal-arrow</infographic></page>"
             )

    assert reason =~ "infographic"
    assert {:error, _} = Kernel.knowledge_parse("---\n- array\n---\nBody")
  end
end
