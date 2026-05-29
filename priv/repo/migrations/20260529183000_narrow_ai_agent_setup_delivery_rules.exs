defmodule BullX.Repo.Migrations.NarrowAiAgentSetupDeliveryRules do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE mailbox_delivery_rules
    SET match_expr = replace(
          match_expr,
          $old$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked" || type == "bullx.action.submitted")$old$,
          $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$
        ),
        updated_at = now()
    WHERE match_expr LIKE '%type == "bullx.message.edited"%'
       OR match_expr LIKE '%type == "bullx.action.submitted"%';
    """)
  end

  def down do
    execute("""
    UPDATE mailbox_delivery_rules
    SET match_expr = replace(
          match_expr,
          $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$,
          $old$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked" || type == "bullx.action.submitted")$old$
        ),
        updated_at = now()
    WHERE match_expr LIKE '%type == "bullx.command.invoked"%';
    """)
  end
end
