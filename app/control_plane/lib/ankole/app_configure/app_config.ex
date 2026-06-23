defmodule Ankole.AppConfigure.AppConfig do
  @moduledoc """
  Database row for one scoped AppConfigure value.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "app_configure" do
    field :scope, :string
    field :key, :string
    field :value, :map

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          scope: String.t(),
          key: String.t(),
          value: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Validates the durable row shape before insert or upsert.

  The application schema keeps the same constraints as the database so normal
  callers get changeset errors, while the database still protects against direct
  SQL writes.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:scope, :key, :value])
    |> validate_required([:scope, :key, :value])
    |> validate_format(:scope, ~r/\A(?:global|agent:.+)\z/)
    |> validate_change(:value, &validate_envelope/2)
    |> unique_constraint([:scope, :key], name: :app_configure_scope_key_unique)
    |> check_constraint(:scope, name: :app_configure_scope_check)
    |> check_constraint(:value, name: :app_configure_value_envelope_check)
  end

  # Tests and some Ecto paths may pass atom-key maps before JSONB round-trips
  # through PostgreSQL. Accepting both shapes keeps validation close to the DB
  # envelope without forcing callers to pre-normalize maps.
  defp validate_envelope(:value, %{"type" => type, "value" => _value})
       when type in ["plaintext", "cipher"] do
    []
  end

  defp validate_envelope(:value, %{type: type, value: _value})
       when type in ["plaintext", "cipher"] do
    []
  end

  defp validate_envelope(:value, _value), do: [value: "must be an AppConfigure envelope"]
end
