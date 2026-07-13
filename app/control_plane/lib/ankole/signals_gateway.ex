defmodule Ankole.SignalsGateway do
  @moduledoc """
  Boundary between signal ingress, actor event handoff, and provider outbox.

  This module is the public facade for binding management, provider-visible
  outbox work, cleanup, and runtime support queries. Provider facts enter through
  `Ankole.SignalsGateway.Ingress`, which owns admission, projection, batching,
  and actor-event handoff.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.SessionController
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.InboundBatches
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.StateCleanup
  alias Ankole.SignalsGateway.Utils
  alias Ankole.SignalsGateway.Visibility

  @doc """
  Appends one durable Actor event inside a caller-owned transaction.
  """
  defdelegate append_actor_event_in_tx(repo, attrs), to: Actors

  @doc false
  defdelegate mark_actor_event_completed_in_tx(repo, event, completed_at),
    to: Actors,
    as: :mark_event_completed_in_tx

  @doc false
  defdelegate process_actor_session_ready(actor_key), to: SessionController, as: :process_ready

  @doc false
  defdelegate list_workers(), to: ActorRuntime

  @doc false
  defdelegate mark_worker_stale_if_due(worker_id, opts \\ []), to: ActorRuntime

  @doc false
  defdelegate delete_worker_if_due(worker_id, opts \\ []), to: ActorRuntime

  @doc false
  defdelegate fail_activation_if_expired(activation_uid, opts \\ []), to: ActorRuntime

  @doc """
  Creates or updates a per-agent signal binding.
  """
  @spec upsert_binding(map()) :: {:ok, Binding.t()} | {:error, term()}
  defdelegate upsert_binding(attrs), to: Bindings

  @doc """
  Lists signal adapters available for operator-managed bindings.
  """
  @spec list_adapters() :: {:ok, [map()]} | {:error, term()}
  defdelegate list_adapters(), to: Bindings

  @spec put_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  defdelegate put_binding(agent_uid, adapter_id, binding_name, attrs), to: Bindings

  @doc """
  Loads an enabled binding by route key.
  """
  @spec get_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  defdelegate get_binding(agent_uid, binding_name), to: Bindings

  @doc """
  Lists signal bindings for one agent, including disabled bindings.
  """
  @spec list_agent_bindings(String.t(), keyword()) ::
          {:ok, [Binding.t()]} | {:error, term()}
  defdelegate list_agent_bindings(agent_uid, opts \\ []), to: Bindings

  @doc """
  Soft-disables a signal binding for one agent.
  """
  @spec disable_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  defdelegate disable_binding(agent_uid, binding_name), to: Bindings

  @doc """
  Lists enabled bindings for an adapter that should have live provider connections.
  """
  @spec list_enabled_bindings(String.t(), keyword()) :: [Binding.t()]
  defdelegate list_enabled_bindings(adapter, opts \\ []), to: Bindings

  @doc """
  Returns the provider and AuthZ-backed channel mirrors visible to a principal.
  """
  @spec visible_channels(String.t(), keyword()) :: [Ankole.SignalsGateway.Channel.t()]
  defdelegate visible_channels(principal_uid, opts \\ []), to: Visibility

  @doc """
  Resolves the globally unique, stable address of one mirrored source entry.
  """
  @spec get_entry_by_document_id(String.t()) :: Entry.t() | nil
  def get_entry_by_document_id(document_id) when is_binary(document_id) do
    Ankole.Repo.get_by(Entry, document_id: document_id)
  end

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
  @spec dispatch_outbox(
          String.t(),
          String.t(),
          String.t(),
          Ankole.SignalsGateway.OutboxAdapter.t() | map(),
          keyword()
        ) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  defdelegate dispatch_outbox(agent_uid, binding_name, outbound_key, adapter, options \\ []),
    to: Outbox

  @doc """
  Dispatches one outbox row by key using the registered signal adapter.
  """
  @spec dispatch_outbox_by_key(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  defdelegate dispatch_outbox_by_key(agent_uid, binding_name, outbound_key, options \\ []),
    to: Outbox

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

  @doc false
  @spec finalize_inbound_batch_by_id(String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def finalize_inbound_batch_by_id(batch_id, batch_revision, opts \\ []) do
    InboundBatches.finalize_inbound_batch_by_id(batch_id, batch_revision, opts)
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    ActorRuntime.runtime_event_snapshot() ++
      InboundBatches.runtime_event_snapshot() ++ Outbox.runtime_event_snapshot()
  end
end
