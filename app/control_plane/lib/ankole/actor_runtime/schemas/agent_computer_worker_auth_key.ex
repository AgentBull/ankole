defmodule Ankole.ActorRuntime.Schemas.AgentComputerWorkerAuthKey do
  @moduledoc """
  Logged worker-scoped pre-auth key material.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]
  @worker_id_format ~r/\A[a-z][a-z0-9_-]{0,62}\z/

  schema "agent_computer_worker_auth_keys" do
    field :worker_id, :string, primary_key: true
    field :pre_auth_key, :string
    field :key_revision, :integer, default: 1
    field :disabled_at, :utc_datetime_usec
    field :last_bootstrap_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(auth_key, attrs) do
    auth_key
    |> cast(attrs, [:worker_id, :pre_auth_key, :key_revision, :disabled_at, :last_bootstrap_at])
    |> normalize_blank([:worker_id, :pre_auth_key])
    |> normalize_lower(:worker_id)
    |> validate_required([:worker_id, :pre_auth_key, :key_revision])
    |> validate_format(:worker_id, @worker_id_format)
    |> validate_number(:key_revision, greater_than: 0)
    |> unique_constraint(:worker_id, name: :agent_computer_worker_auth_keys_pkey)
    |> check_constraint(:worker_id, name: :agent_computer_worker_auth_keys_worker_id_format)
    |> check_constraint(:pre_auth_key,
      name: :agent_computer_worker_auth_keys_pre_auth_key_present
    )
    |> check_constraint(:key_revision, name: :agent_computer_worker_auth_keys_revision_positive)
  end

  defp normalize_blank(changeset, fields) when is_list(fields),
    do: Enum.reduce(fields, changeset, fn field, acc -> normalize_blank(acc, field) end)

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

  defp normalize_lower(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
