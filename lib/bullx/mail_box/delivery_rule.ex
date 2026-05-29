defmodule BullX.MailBox.DeliveryRule do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.Principals.Agent
  alias BullX.RuleEngine.CEL

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @attention [:addressed, :ambient, :command, :action, :lifecycle, :system]

  @type t :: %__MODULE__{}

  schema "mailbox_delivery_rules" do
    field :name, :string
    field :active, :boolean, default: true
    field :priority, :integer
    field :match_expr, :string
    belongs_to :agent, Agent, foreign_key: :agent_uid, references: :uid, type: :string
    field :attention, Ecto.Enum, values: @attention
    field :session_key_template, :string
    field :available_delay_ms, :integer, default: 0
    field :coalesce_key_template, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) when is_map(attrs) do
    rule
    |> cast(attrs, [
      :name,
      :active,
      :priority,
      :match_expr,
      :agent_uid,
      :attention,
      :session_key_template,
      :available_delay_ms,
      :coalesce_key_template,
      :metadata
    ])
    |> validate_required([
      :name,
      :active,
      :priority,
      :match_expr,
      :agent_uid,
      :attention,
      :available_delay_ms,
      :metadata
    ])
    |> validate_non_empty(:name)
    |> validate_non_empty(:match_expr)
    |> validate_number(:priority, greater_than: 0)
    |> validate_number(:available_delay_ms, greater_than_or_equal_to: 0)
    |> validate_match_expr()
    |> validate_json_object(:metadata)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint(:name)
    |> check_constraint(:name, name: :mailbox_delivery_rules_name_present)
    |> check_constraint(:priority, name: :mailbox_delivery_rules_priority_positive)
    |> check_constraint(:match_expr, name: :mailbox_delivery_rules_match_expr_present)
    |> check_constraint(:available_delay_ms,
      name: :mailbox_delivery_rules_available_delay_ms_nonnegative
    )
    |> check_constraint(:metadata, name: :mailbox_delivery_rules_metadata_object)
  end

  defp validate_non_empty(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_binary(value) and String.trim(value) != "" do
        true -> []
        false -> [{field, "must be a non-empty string"}]
      end
    end)
  end

  defp validate_match_expr(changeset) do
    validate_change(changeset, :match_expr, fn :match_expr, expr ->
      case CEL.validate_condition(expr) do
        :ok -> []
        {:error, reason} -> [match_expr: "is invalid: #{reason}"]
      end
    end)
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case BullX.JSON.json_object?(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end
end
