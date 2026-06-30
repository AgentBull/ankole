defmodule Ankole.SignalsGateway do
  @moduledoc """
  Boundary between signal ingress, actor input handoff, and provider outbox.

  This module is the public facade for the SignalsGateway namespace. The
  implementation is split under `Ankole.SignalsGateway.*` by durable ownership:
  binding lookup, ingress admission, fact normalization, provider projection,
  inbound IM batching, actor-input envelope construction, outbox dispatch, and
  TTL cleanup.

  External adapters and runtime code should keep calling this module. The
  namespace split keeps the implementation cohesive without expanding the public
  contract.
  """

  alias Ankole.Actors.ActorInput
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.InboundBatches
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.StateCleanup
  alias Ankole.SignalsGateway.Utils

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @doc """
  Creates or updates a per-agent signal binding.
  """
  @spec upsert_binding(map()) :: {:ok, SignalBinding.t()} | {:error, term()}
  defdelegate upsert_binding(attrs), to: Bindings

  @doc """
  Loads an enabled binding by route key.
  """
  @spec get_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  defdelegate get_binding(agent_uid, binding_name), to: Bindings

  @doc """
  Concrete adapter API for a provider entry receive.
  """
  @spec emit_entry(String.t(), String.t(), map(), keyword()) :: ingress_result()
  defdelegate emit_entry(agent_uid, binding_name, input, options \\ []), to: Ingress

  @doc """
  Concrete adapter API for a provider entry removal.
  """
  @spec emit_entry_removed(String.t(), String.t(), map(), keyword()) :: ingress_result()
  defdelegate emit_entry_removed(agent_uid, binding_name, input, options \\ []), to: Ingress

  @doc """
  Concrete adapter API for reaction changes.
  """
  @spec emit_reaction(String.t(), String.t(), map(), keyword()) :: ingress_result()
  defdelegate emit_reaction(agent_uid, binding_name, input, options \\ []), to: Ingress

  @doc """
  Concrete adapter API for provider actions such as card clicks.
  """
  @spec emit_action(String.t(), String.t(), map(), keyword()) :: ingress_result()
  defdelegate emit_action(agent_uid, binding_name, input, options \\ []), to: Ingress

  @doc """
  Appends an internal ActorInput, such as a timer fire, without provider mirroring.
  """
  @spec emit_internal(String.t(), String.t(), map(), keyword()) :: ingress_result()
  defdelegate emit_internal(agent_uid, binding_name, input, options \\ []), to: Ingress

  @doc """
  Records a provider-visible outbox intent committed by the actor runtime.
  """
  @spec commit_outbox(map()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  defdelegate commit_outbox(attrs), to: Outbox

  @doc """
  Chooses the provider-visible reply operation for an actor input.
  """
  @spec outbox_operation_for_actor_input(ActorInput.t(), module()) ::
          {:ok, atom()} | {:error, term()}
  defdelegate outbox_operation_for_actor_input(actor_input, repo \\ Ankole.Repo), to: Outbox

  @doc """
  Dispatches one outbox row through a concrete adapter runtime.
  """
  @spec dispatch_outbox(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  defdelegate dispatch_outbox(agent_uid, binding_name, outbound_key, adapter, options \\ []),
    to: Outbox

  @doc """
  Lists outbox rows that are ready for a dispatch attempt.
  """
  @spec list_due_outbox(DateTime.t(), pos_integer()) :: [OutboxEntry.t()]
  defdelegate list_due_outbox(now \\ DateTime.utc_now(:microsecond), limit \\ 50), to: Outbox

  @doc """
  Dispatches due outbox rows with a code-owned adapter resolver.
  """
  @spec dispatch_due_outbox(
          (OutboxEntry.t() -> {:ok, map()} | map() | {:error, term()}),
          keyword()
        ) :: [term()]
  defdelegate dispatch_due_outbox(adapter_resolver, options \\ []), to: Outbox

  @doc """
  Removes expired SignalsGateway TTL state.
  """
  @spec cleanup_expired_state(DateTime.t()) :: %{tombstones: non_neg_integer()}
  defdelegate cleanup_expired_state(now \\ DateTime.utc_now(:microsecond)), to: StateCleanup

  @doc """
  Default actor session id derived from a signal channel.
  """
  @spec signal_session_id(String.t()) :: String.t()
  defdelegate signal_session_id(signal_channel_id), to: Utils

  @doc """
  Closes pending inbound IM batches whose quiet window has elapsed.
  """
  @spec finalize_due_inbound_batches(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate finalize_due_inbound_batches(opts \\ []), to: InboundBatches
end
