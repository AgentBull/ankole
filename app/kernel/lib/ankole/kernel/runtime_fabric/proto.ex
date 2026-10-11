defmodule Ankole.Kernel.RuntimeFabric.Proto do
  @moduledoc """
  Compile-time Elixir types and codec for the RuntimeFabric protocol.

  Protox generates `Ankole.RuntimeFabric.V1.*` from `envelope.proto` and
  `rpc.proto` at compile time. Each host checks the envelope version before
  dispatch. Domain consumers check execution references.
  """

  use Protox,
    paths: [Path.expand("../../../../proto", __DIR__)],
    files: [
      Path.expand("../../../../proto/ankole/runtime_fabric/v1/envelope.proto", __DIR__),
      Path.expand("../../../../proto/ankole/runtime_fabric/v1/rpc.proto", __DIR__)
    ]
end
