defmodule Ankole.Brain.SourceConnectorsTest do
  use ExUnit.Case, async: false

  alias Ankole.Brain.SourceConnectors

  @connector Ankole.BrainSourceConnectorFixture

  test "fetch loads a compiled connector before checking its callbacks" do
    :code.purge(@connector)
    :code.delete(@connector)

    assert :code.is_loaded(@connector) == false
    assert {:ok, @connector} = SourceConnectors.fetch("fixture", connector: @connector)
    assert {:file, _path} = :code.is_loaded(@connector)
  end
end
