defmodule Ankole.Conversations.Delivery.PreviewAdapterTest do
  use ExUnit.Case, async: true

  alias Ankole.Conversations.Delivery.PreviewAdapter

  test "visible transient thought leases cleanup without persisting the thought" do
    checkpoint = %{"provider_handle" => "card-1"}
    before = DateTime.utc_now(:microsecond) |> DateTime.add(540, :second)

    result = PreviewAdapter.put_thought_lease(checkpoint, %{"thought" => "working"}, false, 540)
    after_call = DateTime.utc_now(:microsecond) |> DateTime.add(540, :second)

    assert {:ok, deadline, 0} = DateTime.from_iso8601(result["cleanup_at"])
    assert DateTime.compare(deadline, before) in [:eq, :gt]
    assert DateTime.compare(deadline, after_call) in [:eq, :lt]
    assert Map.delete(result, "cleanup_at") == checkpoint
  end

  test "a terminal surface or absent thought removes its previous cleanup lease" do
    checkpoint = %{"cleanup_at" => "old", "provider_handle" => "card-1"}

    for {presentation, final?} <- [
          {%{"thought" => "old thought"}, true},
          {%{"thought" => ""}, false},
          {%{}, false},
          {%{"thought" => nil}, false}
        ] do
      assert %{"provider_handle" => "card-1"} ==
               PreviewAdapter.put_thought_lease(checkpoint, presentation, final?, 540)
    end
  end
end
