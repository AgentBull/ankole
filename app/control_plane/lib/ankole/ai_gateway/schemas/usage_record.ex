defmodule Ankole.AIGateway.Schemas.UsageRecord do
  @moduledoc """
  One counted provider round of an Agent token quota.

  The row keeps the provider usage as the provider reported it. Rows are never
  updated or deleted while the Agent exists, so the table has no `updated_at`
  column and the window sum of `Ankole.AIAgent.TokenQuota` can read it as an
  append-only ledger. Deleting the Agent Principal removes its rows with its
  other AIGateway records.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  # `agent` is a Worker turn, `codex` is a Background Agent Job request.
  @origins ~w(agent codex)

  schema "ai_gateway_usage_records" do
    belongs_to(:subject, Principal,
      foreign_key: :subject_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:origin, :string)
    field(:model, :string)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)

    timestamps()
  end

  @doc """
  Returns the supported origins.
  """
  @spec origins() :: [String.t()]
  def origins, do: @origins

  @doc """
  Builds a changeset for usage ledger rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(usage_record, attrs) do
    usage_record
    |> cast(attrs, [:subject_uid, :origin, :model, :input_tokens, :output_tokens])
    |> validate_required([:subject_uid, :origin, :model, :input_tokens, :output_tokens])
    |> validate_inclusion(:origin, @origins)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:subject_uid)
    |> check_constraint(:origin, name: :ai_gateway_usage_records_origin_check)
    |> check_constraint(:input_tokens, name: :ai_gateway_usage_records_input_tokens_check)
    |> check_constraint(:output_tokens, name: :ai_gateway_usage_records_output_tokens_check)
  end
end
