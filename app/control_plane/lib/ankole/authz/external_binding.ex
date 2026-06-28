defmodule Ankole.AuthZ.ExternalBinding do
  @moduledoc """
  Provider-scoped external subject binding to an AuthZ group.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AuthZ.Group

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]
  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  schema "principal_group_external_bindings" do
    field :provider, :string, primary_key: true
    field :external_id, :string, primary_key: true

    belongs_to :group, Group, type: :binary_id

    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for external authorization binding rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:provider, :external_id, :group_id, :metadata])
    |> normalize_blank([:provider, :external_id])
    |> normalize_provider()
    |> validate_required([:provider, :external_id, :group_id, :metadata])
    |> validate_format(:provider, @provider_format)
    |> validate_map(:metadata)
    |> foreign_key_constraint(:group_id)
    |> unique_constraint(:external_id, name: :principal_group_external_bindings_pkey)
    |> check_constraint(:provider, name: :principal_group_external_bindings_provider_present)
    |> check_constraint(:provider, name: :principal_group_external_bindings_provider_format)
    |> check_constraint(:external_id,
      name: :principal_group_external_bindings_external_id_present
    )
    |> check_constraint(:metadata, name: :principal_group_external_bindings_metadata_object)
  end

  defp normalize_provider(changeset) do
    update_change(changeset, :provider, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
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

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end
end
