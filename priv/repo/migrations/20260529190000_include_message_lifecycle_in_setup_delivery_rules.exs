defmodule BullX.Repo.Migrations.IncludeMessageLifecycleInSetupDeliveryRules do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE mailbox_delivery_rules
    SET match_expr = replace(
          replace(
            match_expr,
            $old1$(type == "bullx.message.received" || type == "bullx.command.invoked" || type == "bullx.agent.abort")$old1$,
            $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$
          ),
          $old2$(type == "bullx.message.received" || type == "bullx.command.invoked")$old2$,
          $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$
        ),
        updated_at = now()
    WHERE match_expr LIKE '%type == "bullx.message.received"%'
      AND match_expr LIKE '%type == "bullx.command.invoked"%'
      AND (
        match_expr LIKE '%type == "bullx.agent.abort"%'
        OR match_expr NOT LIKE '%type == "bullx.message.edited"%'
      );
    """)
  end

  def down do
    execute("""
    UPDATE mailbox_delivery_rules
    SET match_expr = replace(
          match_expr,
          $new$(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked")$new$,
          $old$(type == "bullx.message.received" || type == "bullx.command.invoked")$old$
        ),
        updated_at = now()
    WHERE match_expr LIKE '%type == "bullx.message.edited"%'
      AND match_expr LIKE '%type == "bullx.message.recalled"%'
      AND match_expr LIKE '%type == "bullx.message.deleted"%';
    """)
  end
end
