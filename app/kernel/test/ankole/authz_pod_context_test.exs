defmodule Ankole.Kernel.AuthZPodContextTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel, as: NativeKernel

  test "Pod conditions preserve comprehension bindings and request context" do
    condition = ~s|["10.0.0.1"].exists(ip, context.request.ip == ip)|

    assert NativeKernel.authz_validate_pod_condition(condition) == true
    assert NativeKernel.authz_condition_free_variables(condition) == ["context"]

    assert NativeKernel.authz_condition_free_variables(
             ~s|[1].exists(resource, [resource].all(action, action == resource)) && resource != ""|
           ) == ["resource"]

    assert NativeKernel.authz_validate_pod_condition(
             ~s|[1].exists(x, [2].exists(x, x == 2) && x == 1)|
           ) == true

    for condition <- [~s(resource == "pod:space"), ~s(action == "page_view")] do
      assert NativeKernel.authz_validate_condition(condition) == true
      assert {:error, reason} = NativeKernel.authz_validate_pod_condition(condition)
      assert reason =~ "free variables"
    end

    assert {:error, _} = NativeKernel.authz_validate_condition("unknown == true")
    assert {:error, _} = NativeKernel.authz_condition_free_variables("[")
    assert {:error, _} = NativeKernel.authz_validate_pod_condition(123)
  end

  test "Pod evaluation includes conditional Usersets and denies disabled Principals" do
    snapshot = %{
      "principal" => %{
        "uid" => "alice",
        "type" => "human",
        "status" => "active",
        "membership" => "guest"
      },
      "staticGroupIDs" => [],
      "computedGroups" => [
        %{"id" => "members", "condition" => ~s(principal.membership == "member")}
      ],
      "context" => %{"ip" => "10.0.0.1"},
      "grants" => [
        %{
          "id" => "userset",
          "hasSourcePage" => true,
          "resourcePattern" => "pod:**:target:**",
          "action" => "page_view",
          "condition" => ~s(context.request.ip == "10.0.0.1")
        },
        %{
          "id" => "invalid",
          "principalUID" => "alice",
          "resourcePattern" => "pod:space:**",
          "action" => "page_view",
          "condition" => "principal.uid"
        }
      ]
    }

    assert %{
             "status" => "active",
             "effectiveGroupIDs" => [],
             "satisfiedGrantIDs" => ["userset"],
             "diagnostics" => [%{"id" => "invalid", "kind" => "condition_result_type"}]
           } = NativeKernel.authz_evaluate_pod_context(snapshot)

    assert %{
             "status" => "principal_disabled",
             "effectiveGroupIDs" => [],
             "satisfiedGrantIDs" => []
           } =
             snapshot
             |> put_in(["principal", "status"], "disabled")
             |> NativeKernel.authz_evaluate_pod_context()

    assert {:error, _} = NativeKernel.authz_evaluate_pod_context(%{})
  end
end
