defmodule Ankole.Repo.Migrations.RemoveAiGatewayMessageRole do
  @moduledoc false

  use Ecto.Migration

  def up do
    drop constraint(:ai_gateway_messages, :ai_gateway_messages_role_check)

    alter table(:ai_gateway_messages) do
      remove :role
    end
  end

  def down do
    alter table(:ai_gateway_messages) do
      add :role, :text
    end

    create constraint(:ai_gateway_messages, :ai_gateway_messages_role_check,
             check: "role IS NULL OR role IN ('user', 'assistant', 'tool', 'im_ambient')"
           )

    execute(
      "COMMENT ON COLUMN ai_gateway_messages.role IS 'Legacy transcript/UI role hint; not the authoritative Response item role.'",
      "COMMENT ON COLUMN ai_gateway_messages.role IS NULL"
    )
  end
end
