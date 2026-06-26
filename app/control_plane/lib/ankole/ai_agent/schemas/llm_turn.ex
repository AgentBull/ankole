defmodule Ankole.AIAgent.Schemas.LlmTurn do
  @moduledoc """
  Durable projection of one AI agent generation turn.

  A turn records the user-visible AI work. ActorRuntime references turns, but it
  does not replace this durable AI-agent boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # Why a turn exists, for transcript readability and retry accounting:
  #   generation          - normal turn triggered by new actor input
  #   retry_generation    - re-run of inputs whose prior turn failed (same work,
  #                         labelled so repeated attempts are explainable)
  #   scheduled_task      - turn driven by a scheduler, not live chat
  #   checkback_generation- turn that follows up on earlier deferred work
  #   compression         - turn whose job is to condense older history into a
  #                         summary while preserving concrete facts (file paths,
  #                         IDs, decisions) so later turns lose context, not state
  #   overflow_retry      - re-run after a context-window overflow
  @kinds ~w(generation retry_generation scheduled_task checkback_generation compression overflow_retry)
  # Turn lifecycle. A turn is created `started` (before the worker is even told
  # to run) and moves to exactly one terminal state. `failed` is recoverable:
  # `AIAgent.mark_turn_failed/3` records the error and releases the generation
  # lease so the inputs can be retried.
  @statuses ~w(started succeeded failed cancelled)
  @profiles ~w(primary light heavy codex)

  schema "ai_agent_llm_turns" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    belongs_to :conversation, Conversation, type: :binary_id

    field :kind, :string
    field :status, :string
    field :profile, :string
    field :provider, :string
    field :model, :string
    field :lease_id, :string
    field :call_index, :integer
    field :branch_id, :string
    field :parent_branch_id, :string
    field :trigger_message_id, Ecto.UUID
    field :trigger_event_id, :string
    field :input_message_ids, Ankole.Types.JsonValue, default: []
    field :request_context, :map, default: %{}
    field :request_refs, Ankole.Types.JsonValue, default: []
    field :request_patches, Ankole.Types.JsonValue, default: []
    field :response, :map, default: %{}
    field :tool_results, Ankole.Types.JsonValue, default: []
    field :usage, :map, default: %{}
    field :provider_metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :agent_uid,
      :conversation_id,
      :kind,
      :status,
      :profile,
      :provider,
      :model,
      :lease_id,
      :call_index,
      :branch_id,
      :parent_branch_id,
      :trigger_message_id,
      :trigger_event_id,
      :input_message_ids,
      :request_context,
      :request_refs,
      :request_patches,
      :response,
      :tool_results,
      :usage,
      :provider_metadata,
      :started_at,
      :completed_at
    ])
    |> normalize_blank([
      :agent_uid,
      :kind,
      :status,
      :profile,
      :provider,
      :model,
      :lease_id,
      :branch_id,
      :parent_branch_id,
      :trigger_event_id
    ])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :conversation_id,
      :kind,
      :status,
      :profile,
      :provider,
      :model,
      :input_message_ids,
      :request_context,
      :request_refs,
      :request_patches,
      :response,
      :tool_results,
      :usage,
      :provider_metadata
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:profile, @profiles)
    |> validate_json_array(:input_message_ids)
    |> JsonPayload.validate_map(:request_context, allow_datetime: true)
    |> validate_json_array(:request_refs)
    |> validate_json_array(:request_patches)
    |> JsonPayload.validate_map(:response, allow_datetime: true)
    |> validate_json_array(:tool_results)
    |> JsonPayload.validate_map(:usage, allow_datetime: true)
    |> JsonPayload.validate_map(:provider_metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:conversation_id)
    # A generation lease can drive several provider calls in one local loop, each
    # numbered by `call_index`. Uniqueness over (conversation, lease, call_index)
    # makes each call insert-once: a retried delivery for the same lease and step
    # collides instead of recording a duplicate turn.
    |> unique_constraint([:conversation_id, :lease_id, :call_index],
      name: :ai_agent_llm_turns_generation_call_index
    )
    |> check_constraint(:kind, name: :ai_agent_llm_turns_kind_check)
    |> check_constraint(:status, name: :ai_agent_llm_turns_status_check)
    |> check_constraint(:profile, name: :ai_agent_llm_turns_profile_check)
  end

  # Keeps JSON-array fields portable across the Elixir database boundary. These
  # fields may be filled later by the real computer AI loop, so validation stays
  # structural instead of provider-specific.
  defp validate_json_array(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_list(value) and Enum.all?(value, &json_value?/1) do
        true -> []
        false -> [{field, "must be a JSON array"}]
      end
    end)
  end

  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value), do: true
  defp json_value?(value) when is_binary(value), do: true
  defp json_value?(value) when is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: true
  defp json_value?(values) when is_list(values), do: Enum.all?(values, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_value), do: false

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
