defmodule Ankole.Kernel.AuthZChecksTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel, as: NativeKernel

  test "independent checks preserve single-decision rules and grant subsets" do
    snapshot = %{
      "principal" => %{"uid" => "alice", "type" => "human", "status" => "active"},
      "staticGroupIDs" => [],
      "computedGroups" => [
        %{"id" => "humans", "condition" => ~s(principal.type == "human")}
      ],
      "resource" => "pages",
      "actions" => ["read", "write"],
      "context" => %{"approved" => true},
      "grants" => [
        grant("group", "groupID", "humans", "pages:**", "read", "true && true"),
        grant(
          "direct",
          "principalUID",
          "alice",
          "pages:one",
          "write",
          ~s(resource == "pages:one" && action == "write" && context.request.approved)
        ),
        grant("foreign", "principalUID", "bob", "pages:**", "write", "true")
      ]
    }

    checks = [
      %{"resource" => "pages:one", "action" => "read"},
      %{"resource" => "pages:one", "action" => "write"},
      %{"resource" => "pages:two", "action" => "write"},
      %{"resource" => "pages:one", "action" => "read", "grantIDs" => []},
      %{"resource" => "pages:one", "action" => "write", "grantIDs" => ["direct"]},
      %{"resource" => "pages:two", "action" => "write", "grantIDs" => ["foreign"]},
      %{"resource" => "pages:one", "action" => "read", "grantIDs" => ["missing"]}
    ]

    assert %{"allowed" => allowed, "diagnostics" => []} =
             NativeKernel.authz_authorize_checks(Map.put(snapshot, "checks", checks))

    assert allowed == [true, true, false, false, true, false, false]

    for {check, allowed} <- Enum.zip(checks, allowed) do
      single =
        snapshot
        |> Map.merge(Map.take(check, ["resource", "action"]))
        |> Map.update!("grants", fn grants ->
          case check do
            %{"grantIDs" => ids} -> Enum.filter(grants, &(&1["id"] in ids))
            _ -> grants
          end
        end)

      assert %{"status" => status} = NativeKernel.authz_authorize(single)
      assert allowed == (status == "allow")
    end

    disabled = put_in(snapshot, ["principal", "status"], "disabled")

    assert %{"allowed" => [false, false]} =
             NativeKernel.authz_authorize_checks(
               Map.put(disabled, "checks", Enum.take(checks, 2))
             )
  end

  test "invalid checks fail closed and repeated persisted errors have one diagnostic" do
    snapshot = %{
      "principal" => %{"uid" => "alice", "type" => "human", "status" => "active"},
      "staticGroupIDs" => [],
      "computedGroups" => [],
      "resource" => "pages",
      "actions" => ["read"],
      "grants" => [grant("invalid", "principalUID", "alice", "pages:**", "read", "1")],
      "checks" => [
        %{"resource" => "", "action" => "read"},
        %{"resource" => "pages:one", "action" => ""},
        %{"resource" => "pages:one", "action" => "read"},
        %{"resource" => "pages:two", "action" => "read"}
      ]
    }

    assert %{
             "allowed" => [false, false, false, false],
             "diagnostics" => [%{"id" => "invalid", "kind" => "condition_result_type"}]
           } = NativeKernel.authz_authorize_checks(snapshot)
  end

  defp grant(id, owner_key, owner, pattern, action, condition) do
    %{
      "id" => id,
      owner_key => owner,
      "resourcePattern" => pattern,
      "action" => action,
      "condition" => condition
    }
  end
end
