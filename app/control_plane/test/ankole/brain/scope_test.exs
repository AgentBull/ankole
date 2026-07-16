defmodule Ankole.Brain.ScopeTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.Scope

  test "public conversations may explicitly declare no current channel" do
    assert {:ok,
            %Scope{
              owner_uid: "agent-one",
              readable_store_keys: ["public"],
              writable_store_key: "public",
              current_channel: nil
            }} = Scope.from_metadata(" Agent-One ", %{"brain" => %{"visibility" => "public"}})
  end

  test "DM declarations require a peer, allow a non-chat run, and include public as read-only" do
    metadata = %{
      "brain" => %{
        "visibility" => "dm",
        "peer_uid" => " Human-One ",
        "channel_id" => "oc_dm",
        "channel_kind" => "im_dm"
      }
    }

    assert {:ok,
            %Scope{
              owner_uid: "agent-one",
              readable_store_keys: ["dm:human-one", "public"],
              writable_store_key: "dm:human-one",
              current_channel: %{id: "oc_dm", kind: "im_dm"}
            }} = Scope.from_metadata("agent-one", metadata)

    assert {:ok, %Scope{current_channel: nil, writable_store_key: "dm:human-one"}} =
             Scope.from_metadata("agent-one", %{
               "brain" => %{"visibility" => "dm", "peer_uid" => "human-one"}
             })

    assert {:error, :invalid_brain_scope} =
             Scope.from_metadata("agent-one", %{
               "brain" => %{
                 "visibility" => "dm",
                 "peer_uid" => "human-one",
                 "channel_id" => "partial"
               }
             })
  end

  test "missing or invalid declarations never fall back to ambient data" do
    assert {:error, :missing_brain_scope} = Scope.from_metadata("agent-one", %{})

    assert {:error, :invalid_brain_scope} =
             Scope.from_metadata("agent-one", %{"brain" => %{"visibility" => "private"}})
  end

  test "trusted constructors distinguish all-store read-only from one-store writes" do
    assert {:ok, %Scope{readable_store_keys: :all, writable_store_key: nil}} =
             Scope.for_console("agent-one", :all)

    assert {:ok,
            %Scope{
              readable_store_keys: ["dm:human-one", "public"],
              writable_store_key: "dm:human-one"
            }} = Scope.for_store("agent-one", "dm:Human-One")
  end

  test "read capabilities can only be narrowed to an already-readable store" do
    assert {:ok, dm_scope} = Scope.for_store("agent-one", "dm:human-one")

    assert {:ok, %Scope{readable_store_keys: ["public"], writable_store_key: "dm:human-one"}} =
             Scope.restrict_read_store(dm_scope, "public")

    assert {:error, :brain_store_not_readable} =
             Scope.restrict_read_store(dm_scope, "dm:someone-else")
  end
end
