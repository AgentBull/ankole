defmodule BullX.Runtime.AgenticLoop.Message do
  @moduledoc false

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Runtime.AgenticLoop.Session

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @roles [:system, :user, :assistant, :tool]
  @kinds [:normal, :summary, :command, :error]
  @statuses [:complete, :generating]

  @type t :: %__MODULE__{}

  schema "agent_messages" do
    belongs_to :session, Session, define_field: false

    field :session_id, :binary_id
    field :parent_id, :binary_id
    field :role, Ecto.Enum, values: @roles
    field :kind, Ecto.Enum, values: @kinds
    field :status, Ecto.Enum, values: @statuses, default: :complete
    field :content, BullX.Ecto.JSONB
    field :covers_range, :map
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) when is_map(attrs) do
    message
    |> cast(attrs, [
      :session_id,
      :parent_id,
      :role,
      :kind,
      :status,
      :content,
      :covers_range,
      :metadata
    ])
    |> validate_required([:session_id, :role, :kind, :status, :content, :metadata])
    |> validate_map(:metadata)
    |> validate_optional_map(:covers_range)
    |> validate_summary_coverage()
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:parent_id, name: :agent_messages_parent_session_fk)
    |> unique_constraint(:metadata, name: :agent_messages_route_decision_user_index)
    |> check_constraint(:content, name: :agent_messages_content_array)
    |> check_constraint(:metadata, name: :agent_messages_metadata_object)
    |> check_constraint(:covers_range, name: :agent_messages_covers_range_object)
    |> check_constraint(:covers_range, name: :agent_messages_summary_covers_range)
    |> check_constraint(:parent_id, name: :agent_messages_no_self_parent)
  end

  defp validate_optional_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_nil(value) or is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end

  defp validate_summary_coverage(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :covers_range)} do
      {:summary, %{} = range} ->
        validate_summary_range(changeset, range)

      {:summary, _range} ->
        add_error(changeset, :covers_range, "is required for summary messages")

      {_kind, nil} ->
        changeset

      {_kind, _range} ->
        add_error(changeset, :covers_range, "is only valid for summary messages")
    end
  end

  defp validate_summary_range(changeset, %{"from_id" => from_id, "to_id" => to_id})
       when is_binary(from_id) and is_binary(to_id) do
    changeset
  end

  defp validate_summary_range(changeset, _range) do
    add_error(changeset, :covers_range, "must include from_id and to_id")
  end
end
