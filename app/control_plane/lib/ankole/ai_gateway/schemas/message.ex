defmodule Ankole.AIGateway.Schemas.Message do
  @moduledoc """
  Stored AI-gateway message-log fact (formerly `ai_agent_messages`).

  One row represents one stateful Responses run, one stateful compaction, or one
  internal AI-gateway message fact. AIGateway owns this table; the worker does
  not read or write it directly.

  Row-level `type` + `status` together express full semantics:
    - `type = "message"`: an ordinary response/message fact.
    - `type = "compaction"`: a compression fact (content must include a compaction item).
    - `status = "generating"`: row is in an active actor-event Responses loop.
    - `status = "complete"`: row can enter normal model-chain projection.
    - `status = "error"`: terminal failure; content/metadata.error preserves audit facts.
    - `status = "retracted"`: reserved for future audit/recovery facts and
      excluded from normal history/anchor when present.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # `role` is now just a legacy transcript/UI projection hint, NOT the
  # authoritative Response-item role. It is nullable because function_call and
  # other non-message items do not carry a role. Response.output partitioning is
  # decided by item provenance (item type + item-level role), not this column.
  @roles ~w(user assistant tool im_ambient)
  # Row-level type separates ordinary message facts from compaction facts.
  @types ~w(message compaction)
  # A message row is `generating` while still in an active Responses loop,
  # `complete` once final, `error` on terminal failure, or `retracted` for
  # future audit/recovery facts. v1 IM deletion does not write `retracted`.
  @statuses ~w(generating complete error retracted)

  schema "ai_gateway_messages" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    belongs_to(:conversation, Conversation, type: :binary_id)

    field(:type, :string)
    field(:role, :string)
    field(:status, :string)
    # Self-reference continuation anchor (renders as `previous_response_id` on the API).
    # `resp_#{id}` always equals `resp_#{ai_gateway_messages.id}` (see plan §1.4).
    field(:previous_message_id, Ecto.UUID)
    field(:content, Ankole.Types.JsonValue, default: [])
    field(:covers_until_message_id, Ecto.UUID)
    # Auxiliary facts only: model/provider, usage, provider raw ids, renderer hints,
    # actor_event_id (AIGateway/ActorRuntime correlation key), request refs, compaction refs.
    # Must NOT carry a second item list.
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @doc """
  Builds a changeset for message rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :agent_uid,
      :conversation_id,
      :type,
      :role,
      :status,
      :previous_message_id,
      :content,
      :covers_until_message_id,
      :metadata
    ])
    |> normalize_blank([:agent_uid, :type, :status, :role])
    |> validate_required([
      :agent_uid,
      :conversation_id,
      :type,
      :status,
      :content,
      :metadata
    ])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> validate_json_array(:content)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> validate_type_content_contract()
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:conversation_id)
    |> check_constraint(:role, name: :ai_gateway_messages_role_check)
    |> check_constraint(:type, name: :ai_gateway_messages_type_check)
    |> check_constraint(:status, name: :ai_gateway_messages_status_check)
    |> check_constraint(:content, name: :ai_gateway_messages_content_array)
    |> check_constraint(:metadata, name: :ai_gateway_messages_metadata_object)
    |> unique_constraint(:metadata, name: :ai_gateway_messages_generating_actor_event_index)
    |> unique_constraint(:metadata, name: :ai_gateway_messages_tool_result_journal_key_index)
  end

  # Allows OpenAI-style multi-part content while rejecting structs or atom-keyed
  # maps that would not round-trip through JSON cleanly.
  defp validate_json_array(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_list(value) and Enum.all?(value, &json_value?/1) do
        true -> []
        false -> [{field, "must be a JSON array"}]
      end
    end)
  end

  defp validate_type_content_contract(changeset) do
    case get_field(changeset, :type) do
      "compaction" ->
        changeset
        |> validate_exactly_one_compaction_item()
        |> validate_required([:previous_message_id, :covers_until_message_id])

      "message" ->
        validate_no_compaction_item(changeset)

      _type ->
        changeset
    end
  end

  defp validate_no_compaction_item(changeset) do
    case content_has_compaction_item?(get_field(changeset, :content)) do
      true -> add_error(changeset, :content, "must not include a compaction item")
      false -> changeset
    end
  end

  defp validate_exactly_one_compaction_item(changeset) do
    case count_compaction_items(get_field(changeset, :content)) do
      1 -> changeset
      _count -> add_error(changeset, :content, "must include exactly one compaction item")
    end
  end

  defp content_has_compaction_item?(items) when is_list(items) do
    Enum.any?(items, &compaction_item?/1)
  end

  defp content_has_compaction_item?(_items), do: false

  defp count_compaction_items(items) when is_list(items),
    do: Enum.count(items, &compaction_item?/1)

  defp count_compaction_items(_items), do: 0

  defp compaction_item?(%{"type" => "compaction"}), do: true
  defp compaction_item?(_item), do: false

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
end
