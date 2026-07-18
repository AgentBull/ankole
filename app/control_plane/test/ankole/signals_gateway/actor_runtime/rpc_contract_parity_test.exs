defmodule Ankole.SignalsGateway.ActorRuntime.RPCContractParityTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorRuntime.RPCLane

  @contract_path Path.expand(
                   "../kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json",
                   Mix.Project.project_file() |> Path.dirname()
                 )

  test "dispatch table matches the committed RuntimeFabric RPC contract" do
    contract =
      @contract_path
      |> File.read!()
      |> Torque.decode!()
      |> Map.new(fn entry ->
        {entry["method"], {entry["scope"], entry["effect"], entry["request_type"]}}
      end)

    table =
      Map.new(RPCLane.operations(), fn {method, {_module, _function, scope, request_mod}} ->
        {method, contract_projection(scope, request_mod)}
      end)

    assert table == contract
  end

  # The response side is pinned by the Bun registry only: the Elixir broker
  # returns a self-describing struct and the worker decode is the contract
  # check, so a local response table would duplicate the Bun anchor.
  test "every dispatch row points at an exported broker function" do
    for {method, {module, function, _scope, _request_mod}} <- RPCLane.operations() do
      Code.ensure_loaded!(module)

      assert function_exported?(module, function, 3),
             "#{method} routes to missing #{inspect(module)}.#{function}/3"
    end
  end

  test "every request module is a generated fabric message" do
    for {method, {_module, _function, _scope, request_mod}} <- RPCLane.operations() do
      Code.ensure_loaded!(request_mod)

      assert function_exported?(request_mod, :decode, 1),
             "#{method} request module #{inspect(request_mod)} is not a generated message"
    end
  end

  defp contract_projection(:worker_agent, request_mod),
    do: {"worker_agent", nil, proto_type_name(request_mod)}

  defp contract_projection(:turn_read, request_mod),
    do: {"turn", "read", proto_type_name(request_mod)}

  defp contract_projection(:turn_write, request_mod),
    do: {"turn", "write", proto_type_name(request_mod)}

  defp proto_type_name(request_mod) do
    ["Ankole", "RuntimeFabric", "V1", message] = Module.split(request_mod)
    "ankole.runtime_fabric.v1.#{message}"
  end
end
