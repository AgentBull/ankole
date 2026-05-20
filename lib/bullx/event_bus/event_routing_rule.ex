defmodule BullX.EventBus.EventRoutingRule do
  @moduledoc """
  Durable EventBus route configuration.

  Rules own only matching, target selection, and TargetSession scope policy.
  Business processing and target-owned session continuity belong to the Target.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.EventBus.{Scope, Target}
  alias BullX.RuleEngine.CEL

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @target_types [:ai_agent, :workflow, :command, :work, :blackhole]
  @type target_type :: :ai_agent | :workflow | :command | :work | :blackhole
  @type t :: %__MODULE__{}

  schema "event_routing_rules" do
    field :name, :string
    field :active, :boolean, default: true
    field :priority, :integer
    field :match_expr, :string
    field :target_type, Ecto.Enum, values: @target_types
    field :target_ref, :string
    field :scope_fields, {:array, :string}, default: []

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :name,
      :active,
      :priority,
      :match_expr,
      :target_type,
      :target_ref,
      :scope_fields
    ])
    |> normalize_blackhole_defaults()
    |> validate_required([
      :name,
      :active,
      :priority,
      :match_expr,
      :target_type,
      :scope_fields
    ])
    |> validate_name()
    |> validate_number(:priority, greater_than: 0)
    |> validate_scope_fields()
    |> validate_target_ref()
    |> validate_target_handler()
    |> validate_match_expr()
    |> unique_constraint(:name)
    |> unique_constraint(:priority)
    |> check_constraint(:name, name: :event_routing_rules_name_trimmed_non_empty)
    |> check_constraint(:priority, name: :event_routing_rules_priority_positive)
    |> check_constraint(:target_ref, name: :event_routing_rules_blackhole_target_ref)
  end

  defp validate_name(changeset) do
    validate_change(changeset, :name, fn
      :name, name when is_binary(name) ->
        case name == String.trim(name) and name != "" do
          true -> []
          false -> [name: "must be a trimmed non-empty string"]
        end

      :name, _name ->
        [name: "must be a string"]
    end)
  end

  defp normalize_blackhole_defaults(changeset) do
    case get_field(changeset, :target_type) do
      :blackhole ->
        changeset
        |> put_change(:target_ref, nil)
        |> put_change(:scope_fields, [])

      _target_type ->
        changeset
    end
  end

  defp validate_target_ref(changeset) do
    case get_field(changeset, :target_type) do
      :blackhole ->
        changeset

      nil ->
        changeset

      _target_type ->
        changeset
        |> validate_required([:target_ref])
        |> validate_change(:target_ref, fn
          :target_ref, target_ref when is_binary(target_ref) ->
            case target_ref == String.trim(target_ref) and target_ref != "" do
              true -> []
              false -> [target_ref: "must be a trimmed non-empty string"]
            end

          :target_ref, _target_ref ->
            [target_ref: "must be a string"]
        end)
    end
  end

  defp validate_target_handler(changeset) do
    case {get_field(changeset, :active), get_field(changeset, :target_type)} do
      {true, target_type}
      when target_type in [:ai_agent, :workflow, :command, :work] ->
        case Target.handler_for(target_type) do
          {:ok, _module} ->
            changeset

          {:error, reason} ->
            add_error(changeset, :target_type, "has no configured handler", reason: reason)
        end

      _other ->
        changeset
    end
  end

  defp validate_scope_fields(changeset) do
    case get_field(changeset, :scope_fields) do
      fields when is_list(fields) ->
        Enum.reduce(fields, changeset, fn field, acc ->
          case Scope.valid_scope_field?(field) do
            true -> acc
            false -> add_error(acc, :scope_fields, "contains invalid field #{inspect(field)}")
          end
        end)

      _fields ->
        add_error(changeset, :scope_fields, "must be a list")
    end
  end

  defp validate_match_expr(changeset) do
    case get_field(changeset, :match_expr) do
      expr when is_binary(expr) ->
        case CEL.validate_condition(expr) do
          :ok -> changeset
          {:error, reason} -> add_error(changeset, :match_expr, "is invalid: #{reason}")
        end

      _expr ->
        changeset
    end
  end
end
