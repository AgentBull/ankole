defmodule Ankole.SignalsGateway do
  @moduledoc """
  Boundary between signal ingress, actor event handoff, and provider outbox.

  This module is the public facade for the SignalsGateway namespace. The
  implementation is split under `Ankole.SignalsGateway.*` by durable ownership:
  binding lookup, ingress admission, fact normalization, provider projection,
  inbound IM batching, actor-event envelope construction, outbox dispatch, and
  TTL cleanup.

  External adapters and runtime code should keep calling this module. The
  namespace split keeps the implementation cohesive without expanding the public
  contract.
  """

  alias Ankole.Actors.ActorEvent
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.InboundBatches
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.StateCleanup
  alias Ankole.SignalsGateway.Utils

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @doc """
  Creates or updates a per-agent signal binding.
  """
  @spec upsert_binding(map()) :: {:ok, SignalBinding.t()} | {:error, term()}
  defdelegate upsert_binding(attrs), to: Bindings

  @spec put_lark_binding(String.t(), String.t(), map()) ::
          {:ok, %{binding: SignalBinding.t(), config_key: String.t()}} | {:error, term()}
  defdelegate put_lark_binding(agent_uid, binding_name, config), to: Bindings

  @doc """
  Loads an enabled binding by route key.
  """
  @spec get_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  defdelegate get_binding(agent_uid, binding_name), to: Bindings

  @doc """
  Lists signal bindings for one agent, including disabled bindings.
  """
  @spec list_agent_bindings(String.t(), keyword()) ::
          {:ok, [SignalBinding.t()]} | {:error, term()}
  defdelegate list_agent_bindings(agent_uid, opts \\ []), to: Bindings

  @doc """
  Soft-disables a signal binding for one agent.
  """
  @spec disable_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  defdelegate disable_binding(agent_uid, binding_name), to: Bindings

  @doc """
  Lists enabled bindings for an adapter that should have live provider connections.
  """
  @spec list_enabled_bindings(String.t(), keyword()) :: [SignalBinding.t()]
  defdelegate list_enabled_bindings(adapter, opts \\ []), to: Bindings

  @doc """
  Returns the binding config ref for an outbox row's route.
  """
  @spec outbox_binding_config_ref(OutboxEntry.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate outbox_binding_config_ref(outbox, opts \\ []), to: Bindings

  @doc """
  Returns recent mirrored entry attachments for one channel actor.
  """
  @spec recent_entry_attachments(String.t(), String.t(), DateTime.t(), keyword()) :: [map()]
  def recent_entry_attachments(signal_channel_id, author_id, provider_time, opts \\ []) do
    Projection.recent_entry_attachments(
      Keyword.get(opts, :repo, Ankole.Repo),
      signal_channel_id,
      author_id,
      provider_time,
      opts
    )
  end

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
  Records a provider-visible outbox intent committed by the actor runtime.
  """
  @spec commit_outbox(map()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  defdelegate commit_outbox(attrs), to: Outbox

  @doc """
  Chooses the provider-visible reply operation for an actor event.
  """
  @spec outbox_operation_for_actor_event(ActorEvent.t(), module()) ::
          {:ok, atom()} | {:error, term()}
  defdelegate outbox_operation_for_actor_event(actor_event, repo \\ Ankole.Repo), to: Outbox

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
  @spec finalize_due_inbound_batches(keyword()) :: {:ok, [map()]}
  def finalize_due_inbound_batches(opts \\ []) do
    {:ok, results} = InboundBatches.finalize_due_inbound_batches(opts)
    Enum.each(results, &AIReplyPreview.maybe_start_result_handlers/1)
    {:ok, results}
  end
end
