defmodule BullX.AuthZ.RequestTest do
  use ExUnit.Case, async: true

  alias BullX.AuthZ.Request
  alias BullX.AuthZ.ResourcePattern

  @principal_id "019dc9bc-0000-7000-8000-000000000001"

  test "build/4 normalizes request strings and CEL-compatible context" do
    assert {:ok, request} =
             Request.build(@principal_id, " web_console ", " read ", %{
               "nested" => %{count: 1},
               allowed: true,
               list: ["x", false, nil],
               score: 1.5
             })

    assert request.principal_id == @principal_id
    assert request.resource == "web_console"
    assert request.action == "read"

    assert request.context == %{
             "allowed" => true,
             "nested" => %{"count" => 1},
             "list" => ["x", false, nil],
             "score" => 1.5
           }
  end

  test "build/4 rejects malformed subjects, resource wildcards, action colons, and non-CEL terms" do
    assert {:error, :invalid_request} = Request.build(nil, "web_console", "read", %{})
    assert {:error, :invalid_request} = Request.build("not-a-uuid", "web_console", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_id, "", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_id, "web*", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_id, "web", "", %{})
    assert {:error, :invalid_request} = Request.build(@principal_id, "web", "read:all", %{})
    assert {:error, :invalid_request} = Request.build(@principal_id, "web", "read", nil)
    assert {:error, :invalid_request} = Request.build(@principal_id, "web", "read", %{k: self()})
    assert {:error, :invalid_request} = Request.build(@principal_id, "web", "read", %{k: {1, 2}})
    assert {:error, :invalid_request} = Request.build(@principal_id, "web", "read", %{k: :admin})

    assert {:error, :invalid_request} =
             Request.build(@principal_id, "web", "read", %{nil => true})
  end

  test "permission keys split at the final colon" do
    assert {:ok, "workspace_channel:main", "write"} =
             Request.split_permission_key("workspace_channel:main:write")

    assert {:error, :invalid_request} = Request.split_permission_key("read")
    assert {:error, :invalid_request} = Request.split_permission_key(":read")
    assert {:error, :invalid_request} = Request.split_permission_key("web_console:")
  end

  test "resource patterns match literals and one wildcard" do
    assert :ok = ResourcePattern.validate("workspace_channel:*")
    assert ResourcePattern.match?("workspace_channel:*", "workspace_channel:foo:bar")
    assert ResourcePattern.match?("*", "")
    assert ResourcePattern.match?("*", "anything")
    assert ResourcePattern.match?("a*", "a")
    assert ResourcePattern.match?("*a", "a")
    assert ResourcePattern.match?("a*a", "aa")
    assert ResourcePattern.match?("web_console", "web_console")
    refute ResourcePattern.match?("web_console", "other")
    refute ResourcePattern.match?("a*a", "a")
    refute ResourcePattern.match?("ab*bc", "abc")
    assert ResourcePattern.match?("ab*bc", "abbc")
    refute ResourcePattern.match?("web**", "web_console")

    assert {:error, "must contain at most one '*'"} = ResourcePattern.validate("web**")
  end
end
