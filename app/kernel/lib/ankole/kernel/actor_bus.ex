defmodule Ankole.Kernel.ActorBus do
  @moduledoc """
  Elixir facade for Actor Bus v1 envelope encoding and transport.

  The native kernel owns protobuf serialization, protocol validation, and the
  ZeroMQ ROUTER socket owner. The control plane owns all actor-runtime decisions
  made from received envelopes.
  """

  alias Ankole.Kernel

  @type envelope :: map()
  @type router :: reference()

  @doc """
  Encodes an Actor Bus envelope map as protobuf bytes.
  """
  @spec encode_envelope(envelope()) :: binary() | {:error, String.t()}
  def encode_envelope(envelope) when is_map(envelope),
    do: Kernel.actor_bus_encode_envelope(envelope)

  @doc """
  Decodes Actor Bus protobuf bytes into the public envelope map.
  """
  @spec decode_envelope(binary()) :: envelope() | {:error, String.t()}
  def decode_envelope(bytes) when is_binary(bytes), do: Kernel.actor_bus_decode_envelope(bytes)

  @doc """
  Starts a Rust-owned ZeroMQ ROUTER socket.

  Incoming protobuf frames are decoded in Rust and sent to `owner_pid` as
  `{:actor_bus_router_received, transport_route, envelope_json}` messages.
  """
  @spec router_start(String.t(), pid(), keyword()) :: {:ok, router()} | {:error, String.t()}
  def router_start(endpoint, owner_pid, opts \\ [])
      when is_binary(endpoint) and is_pid(owner_pid) and is_list(opts) do
    opts =
      opts
      |> Map.new()
      |> stringify_keys()
      |> Torque.encode!()

    case Kernel.actor_bus_router_start(endpoint, owner_pid, opts) do
      {:error, reason} -> {:error, reason}
      router -> {:ok, router}
    end
  end

  @doc """
  Returns the actual ROUTER endpoint after ZeroMQ expands wildcard ports.
  """
  @spec router_endpoint(router()) :: String.t() | {:error, String.t()}
  def router_endpoint(router), do: Kernel.actor_bus_router_endpoint(router)

  @doc """
  Sends one envelope to a route without changing actor-runtime truth.
  """
  @spec router_send(router(), String.t(), envelope()) ::
          {:ok, :sent_or_queued} | {:error, atom() | String.t()}
  def router_send(router, transport_route, envelope),
    do: router_send_mandatory(router, transport_route, envelope)

  @doc """
  Sends one envelope with mandatory ROUTER routing enabled.
  """
  @spec router_send_mandatory(router(), String.t(), envelope()) ::
          {:ok, :sent_or_queued} | {:error, atom() | String.t()}
  def router_send_mandatory(router, transport_route, envelope)
      when is_binary(transport_route) and is_map(envelope) do
    envelope_json = Torque.encode!(envelope)

    case Kernel.actor_bus_router_send_mandatory(router, transport_route, envelope_json) do
      "sent_or_queued" -> {:ok, :sent_or_queued}
      {:error, reason} -> {:error, normalize_transport_error(reason)}
      other -> {:error, other}
    end
  end

  @doc """
  Stops the Rust-owned ROUTER socket.
  """
  @spec router_stop(router()) :: :ok | {:error, atom() | String.t()}
  def router_stop(router) do
    case Kernel.actor_bus_router_stop(router) do
      true -> :ok
      {:error, reason} -> {:error, normalize_transport_error(reason)}
      other -> {:error, other}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_transport_error("unknown_route"), do: :unknown_route
  defp normalize_transport_error("backpressure"), do: :backpressure
  defp normalize_transport_error("timeout"), do: :timeout
  defp normalize_transport_error("socket_closed"), do: :socket_closed
  defp normalize_transport_error(reason), do: reason
end
