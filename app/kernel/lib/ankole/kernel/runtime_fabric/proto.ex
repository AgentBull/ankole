defmodule Ankole.Kernel.RuntimeFabric.Proto do
  @moduledoc """
  Compile-time Elixir types and codec for the RuntimeFabric protocol.

  `envelope.proto` declares the envelope frames and `rpc.proto` the RPC
  business payload messages. Protox derives these modules
  (`Ankole.RuntimeFabric.V1.*`) directly from those files at compile time,
  mirroring how `prost-build` derives the Rust envelope types, so the Elixir
  shape cannot drift from the proto. Semantic protocol validation stays in
  the Rust kernel at the transport boundary; RPC payloads are opaque bytes to
  the kernel.
  """

  use Protox,
    files: [
      Path.expand("../../../../proto/ankole/runtime_fabric/v1/envelope.proto", __DIR__),
      Path.expand("../../../../proto/ankole/runtime_fabric/v1/rpc.proto", __DIR__)
    ]
end
