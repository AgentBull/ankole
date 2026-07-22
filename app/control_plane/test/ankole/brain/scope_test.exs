defmodule Ankole.Brain.ScopeTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.Scope

  test "shared conversations may explicitly declare no current channel" do
    assert {:ok,
            %Scope{
              owner_uid: "agent-one",
              readable_store_keys: ["shared", "self"],
              writable_store_key: "shared",
              current_channel: nil
            }} = Scope.from_metadata(" Agent-One ", %{"brain" => %{"visibility" => "shared"}})
  end

  test "DM declarations require a peer, allow a non-chat run, and include self and shared as read-only" do
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
              readable_store_keys: ["dm:human-one", "self", "shared"],
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
              readable_store_keys: ["dm:human-one", "self", "shared"],
              writable_store_key: "dm:human-one"
            }} = Scope.for_store("agent-one", "dm:Human-One")
  end

  test "read capabilities can only be narrowed to an already-readable store" do
    assert {:ok, dm_scope} = Scope.for_store("agent-one", "dm:human-one")

    assert {:ok, %Scope{readable_store_keys: ["shared"], writable_store_key: "dm:human-one"}} =
             Scope.restrict_read_store(dm_scope, "shared")

    assert {:error, :brain_store_not_readable} =
             Scope.restrict_read_store(dm_scope, "dm:someone-else")
  end

  test "self and confidential channel declarations keep shared readable but never writable" do
    assert {:ok,
            %Scope{
              readable_store_keys: ["self", "shared"],
              writable_store_key: "self"
            }} = Scope.from_metadata("agent-one", %{"brain" => %{"visibility" => "self"}})

    assert {:ok,
            %Scope{
              readable_store_keys: ["channel:oc_secret", "self", "shared"],
              writable_store_key: "channel:oc_secret",
              current_channel: %{id: "oc_secret", kind: "im_group"}
            }} =
             Scope.from_metadata("agent-one", %{
               "brain" => %{
                 "visibility" => "channel",
                 "channel_id" => "oc_secret",
                 "channel_kind" => "im_group"
               }
             })
  end
end
