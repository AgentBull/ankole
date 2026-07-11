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
      |> Map.new(fn entry -> {entry["method"], {entry["scope"], entry["effect"]}} end)

    table =
      Map.new(RPCLane.operations(), fn {method, {_module, _function, scope}} ->
        {method, contract_projection(scope)}
      end)

    assert table == contract
  end

  test "every dispatch row points at an exported broker function" do
    for {method, {module, function, scope}} <- RPCLane.operations() do
      arity = if scope == :worker_agent, do: 2, else: 3
      Code.ensure_loaded!(module)

      assert function_exported?(module, function, arity),
             "#{method} routes to missing #{inspect(module)}.#{function}/#{arity}"
    end
  end

  defp contract_projection(:worker_agent), do: {"worker_agent", nil}
  defp contract_projection(:turn_read), do: {"turn", "read"}
  defp contract_projection(:turn_write), do: {"turn", "write"}
end
