defmodule Ankole.Conversations.Observation do
  @moduledoc """
  Internal constructed ingress fact used after adapter input normalization.

  Adapter-facing APIs accept concrete maps, but the gateway pipeline should not
  pass those maps through as durable intent. Each accepted ingress shape becomes
  this struct before routing, mirroring, or Signal planning.
  """

  # Every accepted signal shape is represented by this one struct. Only the
  # routing identity that all shapes share is enforced; the rest of the fields
  # are populated per-kind by the constructors below, so most are nil for any
  # given fact.
  @enforce_keys [:kind, :agent_uid, :binding_name, :adapter, :source_event_id]
  defstruct [
    :kind,
    :agent_uid,
    :binding_name,
    :adapter,
    :source_event_id,
    :conversation_id,
    :provider_conversation_id,
    :provider_message_id,
    :reply_to_provider_message_id,
    :reply_to,
    :provider_thread_id,
    :channel_kind,
    :reply_mode,
    :channel_name,
    :channel_visibility,
    :channel_metadata,
    :channel_raw_payload,
    :text,
    :formatted_content,
    :attachments,
    :links,
    :author,
    :mentions,
    :metadata,
    :raw_payload,
    :provider_time,
    :explicit?,
    :mirror_only?,
    :signal_type,
    :command_prefixes,
    :sender_key,
    :gateway_time,
    :lifecycle_kind,
    :provider_lifecycle_kind,
    :reaction_key,
    :actor_key,
    :action,
    :raw_reaction_key,
    :action_id,
    :session_id,
    :command_payload
  ]

  @type t :: %__MODULE__{}

  @doc """
  Returns true when the entry unambiguously addresses the agent: every DM
  qualifies, and a group entry qualifies when its mention or reply target
  resolved to this agent.
  """
  @spec addressed_im_entry?(t()) :: boolean()
  def addressed_im_entry?(%__MODULE__{channel_kind: :im_dm}), do: true
  def addressed_im_entry?(%__MODULE__{channel_kind: :im_group, explicit?: true}), do: true
  def addressed_im_entry?(%__MODULE__{}), do: false

  @doc """
  Constructs a provider entry receive fact.
  """
  @spec entry(map()) :: {:ok, t()}
  def entry(attrs), do: new(:entry_received, attrs)

  @doc """
  Constructs a provider entry lifecycle fact.
  """
  @spec lifecycle(map()) :: {:ok, t()}
  def lifecycle(attrs), do: new(:entry_lifecycle, attrs)

  @doc """
  Constructs a provider reaction fact.
  """
  @spec reaction(map()) :: {:ok, t()}
  def reaction(attrs), do: new(:reaction, attrs)

  @doc """
  Constructs a provider action fact.
  """
  @spec action(map()) :: {:ok, t()}
  def action(attrs), do: new(:action, attrs)

  defp new(kind, attrs), do: {:ok, struct!(__MODULE__, Map.put(attrs, :kind, kind))}
end
