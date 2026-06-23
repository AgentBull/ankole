defmodule Ankole.Principals.Agent do
  @moduledoc """
  Agent-specific subtype row keyed by `principals.uid`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agents" do
    belongs_to :principal, Principal,
      foreign_key: :uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :type, Ecto.Enum, values: [:ai_colleague], default: :ai_colleague
    field :role, :string
    field :options, :map, default: %{}

    belongs_to :created_by_principal, Principal,
      foreign_key: :created_by_principal_uid,
      references: :uid,
      type: :string

    timestamps()
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:uid, :type, :role, :options, :created_by_principal_uid])
    |> normalize_blank([:role, :created_by_principal_uid])
    |> normalize_uid([:uid, :created_by_principal_uid])
    |> validate_required([:uid, :type, :role, :options])
    |> validate_map(:options)
    |> foreign_key_constraint(:uid)
    |> foreign_key_constraint(:created_by_principal_uid)
    |> unique_constraint(:uid, name: :agents_pkey)
    |> check_constraint(:role, name: :agents_role_present)
    |> check_constraint(:options, name: :agents_options_object)
  end

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

  defp normalize_uid(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_uid(&2, &1))
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end
end
