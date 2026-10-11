defmodule Ankole.SignalsGateway.ActorRuntime.RPCLaneTest do
  use ExUnit.Case, async: true
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane

  test "every dispatch row points at an exported broker function" do
    for {method, {module, function, _scope, _request_mod, _response_mod}} <-
          RPCLane.operations() do
      Code.ensure_loaded!(module)

      assert function_exported?(module, function, 3),
             "#{method} routes to missing #{inspect(module)}.#{function}/3"
    end
  end
end
