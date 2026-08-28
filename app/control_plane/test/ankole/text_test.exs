defmodule Ankole.TextTest do
  use ExUnit.Case, async: true

  alias Ankole.Text

  test "UTF-8 prefixes and suffixes end at character boundaries" do
    assert Text.utf8_prefix("开终", 4) == "开"
    assert Text.utf8_suffix("开终", 4) == "终"
  end

  test "bounded windows preserve valid UTF-8 at both ends" do
    excerpt = Text.truncate_utf8_window("开" <> String.duplicate("大", 100) <> "终", 64)

    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= 64
    assert String.starts_with?(excerpt, "开")
    assert String.ends_with?(excerpt, "终")
    assert excerpt =~ "[truncated]"
  end
end
