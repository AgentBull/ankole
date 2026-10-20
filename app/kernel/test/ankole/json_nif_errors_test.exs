defmodule Ankole.Kernel.JSONNIFErrorsTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel

  test "Markdoc preserves native input errors without trying to decode the error tuple" do
    assert {:error, reason} = Kernel.brain_markdoc_analyze(<<255>>)
    assert is_binary(reason)

    assert %{"segments" => [%{"scope" => "world", "text" => "public"}]} =
             Kernel.brain_markdoc_analyze("public")
  end

  test "both AuthZ entry points preserve invalid snapshot errors" do
    for authorize <- [&Kernel.authz_authorize/1, &Kernel.authz_authorize_all/1] do
      assert {:error, reason} = authorize.(%{})
      assert is_binary(reason)
    end
  end
end
