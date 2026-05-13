defmodule BullX.Principals.Agent do
  @moduledoc """
  Agent-specific extension row for an Agent Principal.

  `profile` stays JSONB in PostgreSQL, but each Agent type owns Elixir casting
  and validation before a profile can be persisted.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.AgentProfiles.AgenticLoop
  alias BullX.Principals.Principal

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "agents" do
    belongs_to :principal, Principal, primary_key: true
    field :type, Ecto.Enum, values: [:agentic_loop], default: :agentic_loop
    field :profile, :map, default: %{}
    belongs_to :created_by_principal, Principal

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:principal_id, :type, :profile, :created_by_principal_id])
    |> validate_required([:principal_id, :type, :profile])
    |> validate_map(:profile)
    |> validate_profile()
    |> foreign_key_constraint(:principal_id)
    |> foreign_key_constraint(:created_by_principal_id)
    |> unique_constraint(:principal_id, name: :agents_pkey)
    |> check_constraint(:profile, name: :agents_profile_object)
  end

  def main_llm(%__MODULE__{type: :agentic_loop, profile: profile}),
    do: AgenticLoop.main_llm(profile)

  def compression_llm(%__MODULE__{type: :agentic_loop, profile: profile}),
    do: AgenticLoop.compression_llm(profile)

  def heavy_llm(%__MODULE__{type: :agentic_loop, profile: profile}),
    do: AgenticLoop.heavy_llm(profile)

  defp validate_profile(changeset) do
    case {get_field(changeset, :type), get_field(changeset, :profile)} do
      {:agentic_loop, profile} -> validate_agentic_loop_profile(changeset, profile)
      _other -> changeset
    end
  end

  defp validate_agentic_loop_profile(changeset, profile) do
    case AgenticLoop.cast(profile) do
      {:ok, normalized} ->
        put_change(changeset, :profile, normalized)

      {:error, fields} ->
        Enum.reduce(fields, changeset, fn field, acc ->
          add_error(acc, :profile, "invalid agentic_loop #{field}")
        end)
    end
  end
end
