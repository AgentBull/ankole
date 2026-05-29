defmodule BullX.Repo.Migrations.RewriteLegacyImgatewayDeliveryRules do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE mailbox_delivery_rules
    SET match_expr = replace(
          match_expr,
          $old$type.startsWith("bullx.im.message.")$old$,
          $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$
        ),
        updated_at = now()
    WHERE match_expr LIKE '%type.startsWith("bullx.im.message.")%';
    """)
  end

  def down do
    execute("""
    UPDATE mailbox_delivery_rules
    SET match_expr = replace(
          match_expr,
          $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$,
          $old$type.startsWith("bullx.im.message.")$old$
        ),
        updated_at = now()
    WHERE match_expr LIKE '%type == "bullx.message.received"%';
    """)
  end
end
