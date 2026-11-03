defmodule Ankole.Kernel.JSONNIFErrorsTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel

  test "knowledge preserves native input errors without decoding the error tuple" do
    assert {:error, reason} = Kernel.knowledge_parse(<<255>>)
    assert is_binary(reason)

    assert {:ok, %{xml: "<page><p>public</p></page>", metadata: %{}}} =
             Kernel.knowledge_parse("public")
  end

  test "both AuthZ entry points preserve invalid snapshot errors" do
    for authorize <- [&Kernel.authz_authorize/1, &Kernel.authz_authorize_all/1] do
      assert {:error, reason} = authorize.(%{})
      assert is_binary(reason)
    end
  end
end
