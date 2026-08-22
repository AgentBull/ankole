defmodule Ankole.Repo.Migrations.RemoveConfidentialMemoryFromSignalGatewayBindings do
  @moduledoc false

  use Ecto.Migration

  def change do
    alter table(:signal_gateway_bindings) do
      remove :confidential_memory, :boolean, null: false, default: false
    end
  end
end
