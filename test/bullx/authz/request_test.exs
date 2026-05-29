defmodule BullX.AuthZ.RequestTest do
  use ExUnit.Case, async: true

  alias BullX.AuthZ.Request
  alias BullX.AuthZ.ResourcePattern

  @principal_uid "authz-request-principal"

  test "build/4 normalizes request strings and CEL-compatible context" do
    assert {:ok, request} =
             Request.build(@principal_uid, " web_console ", " read ", %{
               "nested" => %{count: 1},
               allowed: true,
               list: ["x", false, nil],
               score: 1.5
             })

    assert request.principal_uid == @principal_uid
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
    assert {:error, :invalid_request} = Request.build("   ", "web_console", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web*", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web?", "read", %{})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web", "", %{})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web", "read:all", %{})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web", "read", nil)
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web", "read", %{k: self()})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web", "read", %{k: {1, 2}})
    assert {:error, :invalid_request} = Request.build(@principal_uid, "web", "read", %{k: :admin})

    assert {:error, :invalid_request} =
             Request.build(@principal_uid, "web", "read", %{nil => true})
  end

  test "permission keys split at the final colon" do
    assert {:ok, "workspace_channel:main", "write"} =
             Request.split_permission_key("workspace_channel:main:write")

    assert {:error, :invalid_request} = Request.split_permission_key("read")
    assert {:error, :invalid_request} = Request.split_permission_key(":read")
    assert {:error, :invalid_request} = Request.split_permission_key("web_console:")
  end

  test "resource patterns match glob syntax through the Rust decision path" do
    assert :ok = ResourcePattern.validate("workspace_channel:*")
    assert ResourcePattern.match?("workspace_channel:*", "workspace_channel:foo")
    refute ResourcePattern.match?("workspace_channel:*", "workspace_channel:foo:bar")
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
    assert ResourcePattern.match?("workspace:*", "workspace:foo")
    refute ResourcePattern.match?("workspace:*", "workspace:foo:bar")
    assert ResourcePattern.match?("workspace:**", "workspace:foo:bar")
    assert ResourcePattern.match?("workspace:**:member", "workspace:foo:bar:member")
    refute ResourcePattern.match?("workspace:**:member", "workspace:foo:bar:viewer")
    assert ResourcePattern.match?("web**", "web_console")

    assert {:error, reason} = ResourcePattern.validate("[")
    assert reason =~ "invalid resource glob"
  end
end
