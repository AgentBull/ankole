defmodule Ankole.AgentWorkers.RPCLaneTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.RPCLane

  test "dispatch covers exactly the control-plane RPC contract" do
    contract =
      Path.expand("../../../../kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json", __DIR__)

    methods =
      for %{"method" => method} = entry <- Torque.decode!(File.read!(contract)),
          entry["owner"] != "worker",
          do: method

    assert Enum.sort(Map.keys(RPCLane.operations())) == Enum.sort(methods)
  end

  test "every dispatch row points at an exported broker function" do
    for {method, {module, function, _scope, _request_mod, _response_mod}} <-
          RPCLane.operations() do
      Code.ensure_loaded!(module)

      assert function_exported?(module, function, 3),
             "#{method} routes to missing #{inspect(module)}.#{function}/3"
    end
  end
end
