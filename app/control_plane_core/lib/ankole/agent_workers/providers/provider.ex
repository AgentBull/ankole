defmodule Ankole.AgentWorkers.Providers.Provider do
  @moduledoc "A Worker pool: one kind, its unchanged YAML, and encrypted credentials."

  use Ankole.Schema, tenancy: :site
  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "worker_providers" do
    field :provider_id, :string
    field :kind, :string
    field :display_name, :string
    field :config, :string
    field :credentials, :map, default: %{}, redact: true
    field :is_default, :boolean, default: false
    field :settings, :map, virtual: true
    field :secrets, :map, virtual: true, redact: true
    field :settings_digest, :string, virtual: true
    field :runtime, :map, virtual: true
    timestamps()
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:provider_id, :kind, :display_name, :config, :credentials, :is_default],
      empty_values: []
    )
    |> validate_required([:provider_id, :kind, :display_name, :config, :credentials, :is_default])
    |> validate_format(:provider_id, ~r/\A[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/)
    |> immutable(:provider_id)
    |> immutable(:kind)
    |> unique_constraint(:provider_id)
    |> unique_constraint(:is_default, name: :worker_providers_one_default)
    |> foreign_key_constraint(:provider_id, name: :agent_workers_provider_id_fkey)
  end

  defp immutable(%{data: %{__meta__: %{state: :loaded}}} = changeset, field) do
    if changed?(changeset, field),
      do: add_error(changeset, field, "cannot change after creation"),
      else: changeset
  end

  defp immutable(changeset, _field), do: changeset
end
