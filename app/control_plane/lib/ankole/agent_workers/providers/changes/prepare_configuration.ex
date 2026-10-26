defmodule Ankole.AgentWorkers.Providers.Changes.PrepareConfiguration do
  @moduledoc false
  use Ash.Resource.Change

  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers.{Configuration, Credentials, YAML}

  @impl true
  def change(changeset, _opts, _context) do
    # Credentials bind to the resource's declared ID before the database write.
    changeset = Ash.Changeset.set_defaults(changeset, changeset.action_type, true)

    with {:ok, row} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, kind} <- ProviderKind.fetch(row.kind),
         definition = kind.definition(),
         {:ok, settings} <- Configuration.parse(definition.schema, row.config),
         :ok <- immutable_location(changeset, definition.schema, settings),
         {:ok, credentials, secrets} <-
           Credentials.prepare(
             %{changeset.data | id: row.id},
             kind,
             definition,
             Ash.Changeset.get_argument(changeset, :credential_input)
           ),
         :ok <- Credentials.validate(kind, definition, settings, secrets) do
      Ash.Changeset.force_change_attribute(changeset, :credentials, credentials)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ankole.Errors.Invalid.Rejected.exception(reason: reason)
        )
    end
  end

  defp immutable_location(%{action_type: :create}, _schema, _settings), do: :ok

  defp immutable_location(changeset, schema, settings) do
    with {:ok, before, _locations} <- YAML.parse(changeset.data.config),
         before = Configuration.defaults(schema, before),
         do: Configuration.unchanged_location(schema, before, settings)
  end
end
