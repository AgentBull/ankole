defmodule Ankole.Kernel.RuntimeFabric.Proto do
  @moduledoc """
  Compile-time Elixir types and codec for the RuntimeFabric envelope.

  `envelope.proto` is the only structural declaration of the envelope protocol.
  Protox derives these modules (`Ankole.RuntimeFabric.V1.*`) directly from that
  file at compile time, mirroring how `prost-build` derives the Rust types, so
  the Elixir shape cannot drift from the proto. Semantic protocol validation
  stays in the Rust kernel at the transport boundary.
  """

  use Protox,
    files: [Path.expand("../../../../proto/ankole/runtime_fabric/v1/envelope.proto", __DIR__)]
end
