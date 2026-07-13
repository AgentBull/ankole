defmodule Ankole.Repo.Migrations.SetSignalBindingDefaultRecordOnly do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE signal_gateway_bindings ALTER COLUMN unaddressed_group_message_policy SET DEFAULT 'record_only'"
    )
  end

  def down do
    execute(
      "ALTER TABLE signal_gateway_bindings ALTER COLUMN unaddressed_group_message_policy SET DEFAULT 'ignore'"
    )
  end
end
