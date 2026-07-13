defmodule Ankole.SignalsGateway.ActorRuntime.WorkerEnv.EnvVar do
  @moduledoc """
  Database row for one operator-defined Agent Computer shell variable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "agent_computer_worker_envs" do
    field :scope, :string
    field :name, :string
    field :secret, :boolean
    field :value, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          scope: String.t(),
          name: String.t(),
          secret: boolean(),
          value: String.t(),
          description: String.t() | nil,
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
    |> cast(attrs, [:scope, :name, :secret, :value, :description])
    |> validate_required([:scope, :name, :secret, :value])
    |> validate_format(:scope, ~r/\A(?:global|agent:.+)\z/)
    |> validate_format(:name, ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    |> unique_constraint([:scope, :name], name: :agent_computer_worker_envs_scope_name_unique)
    |> check_constraint(:scope, name: :agent_computer_worker_envs_scope_check)
    |> check_constraint(:name, name: :agent_computer_worker_envs_name_check)
  end
end
