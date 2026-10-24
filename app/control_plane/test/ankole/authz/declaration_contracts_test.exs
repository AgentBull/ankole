defmodule Ankole.AuthZ.DeclarationContractsTest do
  use ExUnit.Case, async: false

  test "a resource cannot expose a routed action without an authorization rule" do
    assert_dsl_error(~r/Every routed action needs/, fn ->
      compile_resource("""
      json_api do
        type("authz_contract_probe")
        routes do
          route(:get, "/probe", :probe, name: "probe")
        end
      end
      authz do scope(:pod) end
      """)
    end)
  end

  test "a permission template requires an explicit supported target resolver" do
    for resolver <- ["", "resolve_param(:uid, :unknown)"] do
      assert_dsl_error(~r/explicit target resolvers/, fn ->
        compile_resource("""
        authz do
          scope(:pod)
          #{resolver}
          allow(:probe, resource: "tenant_console:principal:{uid}", action: "read")
        end
        """)
      end)
    end
  end

  test "a protected domain cannot disable native authorization" do
    name = "Ankole.AuthZ.DomainContractProbe#{System.unique_integer([:positive])}"

    assert_dsl_error(~r/Protected routes must enable authorization/, fn ->
      Code.compile_string("""
      defmodule #{name} do
        use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]
        resources do resource(Ankole.Principals.PodAdminOperations) end
        json_api do authorize?(false) end
      end
      """)
    end)
  end

  test "a domain rejects an exposed resource that omits the native authorizer or extension" do
    for options <- ["", ", authorizers: [Ankole.AuthZ.Authorizer]"] do
      suffix = System.unique_integer([:positive])
      resource = "Ankole.AuthZ.UnprotectedResource#{suffix}"
      domain = "Ankole.AuthZ.UnprotectedDomain#{suffix}"

      Code.compile_string("""
      defmodule #{resource} do
        use Ankole.Ash.OperationResource, domain: nil#{options}
        actions do
          action :probe, :boolean do
            run(fn _, _ -> {:ok, true} end)
          end
        end
      end
      """)

      assert_dsl_error(~r/Protected routes must enable authorization/, fn ->
        Code.compile_string("""
        defmodule #{domain} do
          use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]
          resources do resource(#{resource}) end
          json_api do
            authorize?(true)
            routes do
              base_route "/probe", #{resource} do
                route(:get, "/", :probe, name: "unprotectedProbe")
              end
            end
          end
        end
        """)
      end)
    end
  end

  test "public entry declarations require both the public scope and check" do
    for {scope, check} <- [{:pod, :public}, {:public, :guardrail}] do
      assert_dsl_error(~r/Every routed action needs/, fn ->
        compile_resource("""
        authz do
          scope(:#{scope})
          allow(:probe, check: :#{check})
        end
        """)
      end)
    end
  end

  defp compile_resource(definition) do
    name = "Ankole.AuthZ.ResourceContractProbe#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Ankole.Ash.OperationResource, domain: nil,
        authorizers: [Ankole.AuthZ.Authorizer], extensions: [Ankole.AuthZ.Extension]
      actions do
        action :probe, :boolean do
          run(fn _, _ -> {:ok, true} end)
        end
      end
      #{definition}
    end
    """)
  end

  defp assert_dsl_error(pattern, fun) do
    {_result, diagnostics} = Code.with_diagnostics(fun)

    assert Enum.any?(diagnostics, &Regex.match?(pattern, &1.message)),
           "Expected DSL diagnostic #{inspect(pattern)}, got #{inspect(diagnostics)}"
  end
end
