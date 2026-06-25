defmodule Ankole.AIAgent.Schemas.Message do
  @moduledoc """
  Durable AI agent transcript message.

  Messages are the conversation history that the computer-side AI loop will read
  through the file/runtime view. Runtime delivery state is intentionally kept in
  ActorRuntime tables instead of being embedded here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @roles ~w(user assistant tool im_ambient)
  @kinds ~w(normal summary introspection error)
  @statuses ~w(generating complete)

  schema "ai_agent_messages" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    belongs_to :conversation, Conversation, type: :binary_id

    field :role, :string
    field :kind, :string
    field :status, :string
    field :content, Ankole.Types.JsonValue, default: []
    field :agent_message, :map
    field :covers_range, :map
    field :event_source, :string
    field :event_id, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :agent_uid,
      :conversation_id,
      :role,
      :kind,
      :status,
      :content,
      :agent_message,
      :covers_range,
      :event_source,
      :event_id,
      :metadata
    ])
    |> normalize_blank([:agent_uid, :role, :kind, :status, :event_source, :event_id])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :conversation_id,
      :role,
      :kind,
      :status,
      :content,
      :metadata
    ])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_json_array(:content)
    |> validate_optional_map(:agent_message)
    |> validate_optional_map(:covers_range)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :event_source, :event_id],
      name: :ai_agent_messages_inbound_event_index
    )
    |> check_constraint(:role, name: :ai_agent_messages_role_check)
    |> check_constraint(:kind, name: :ai_agent_messages_kind_check)
    |> check_constraint(:status, name: :ai_agent_messages_status_check)
    |> check_constraint(:content, name: :ai_agent_messages_content_array)
    |> check_constraint(:metadata, name: :ai_agent_messages_metadata_object)
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

  defp validate_optional_map(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> JsonPayload.validate_map(changeset, field, allow_datetime: true)
    end
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
