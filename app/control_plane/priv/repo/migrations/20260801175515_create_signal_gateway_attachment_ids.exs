defmodule Ankole.Repo.Migrations.CreateSignalGatewayAttachmentIds do
  use Ecto.Migration

  def up do
    execute("""
    CREATE SEQUENCE signal_gateway_attachment_id_seq
      AS bigint
      START WITH 10000
      MINVALUE 10000
      MAXVALUE 9007199254740991
      NO CYCLE
    """)
  end

  def down do
    execute("DROP SEQUENCE signal_gateway_attachment_id_seq")
  end
end
