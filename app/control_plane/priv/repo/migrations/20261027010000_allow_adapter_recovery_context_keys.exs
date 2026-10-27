defmodule Ankole.Repo.Migrations.AllowAdapterRecoveryContextKeys do
  use Ecto.Migration

  def up do
    drop constraint(:deliveries, :deliveries_recovery_state_adapter_only)
  end

  def down do
    raise "Adapter recovery context can contain any JSON object keys"
  end
end
