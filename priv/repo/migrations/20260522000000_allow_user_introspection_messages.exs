defmodule BullX.Repo.Migrations.AllowUserIntrospectionMessages do
  use Ecto.Migration

  @new_constraint """
  (role = 'user' AND kind = 'normal' AND status = 'complete') OR
  (role = 'user' AND kind = 'introspection' AND status = 'complete') OR
  (role = 'assistant' AND kind = 'normal' AND status IN ('generating', 'complete')) OR
  (role = 'assistant' AND kind = 'summary' AND status = 'complete') OR
  (role = 'assistant' AND kind = 'error' AND status = 'complete') OR
  (role = 'tool' AND kind = 'normal' AND status = 'complete') OR
  (role = 'im_ambient' AND kind = 'normal' AND status = 'complete') OR
  (role = 'im_ambient' AND kind = 'introspection' AND status = 'complete')
  """

  @old_constraint """
  (role = 'user' AND kind = 'normal' AND status = 'complete') OR
  (role = 'assistant' AND kind = 'normal' AND status IN ('generating', 'complete')) OR
  (role = 'assistant' AND kind = 'summary' AND status = 'complete') OR
  (role = 'assistant' AND kind = 'error' AND status = 'complete') OR
  (role = 'tool' AND kind = 'normal' AND status = 'complete') OR
  (role = 'im_ambient' AND kind = 'normal' AND status = 'complete') OR
  (role = 'im_ambient' AND kind = 'introspection' AND status = 'complete')
  """

  def up do
    execute(
      "ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_valid_role_kind_status"
    )

    create constraint(:conversation_messages, :conversation_messages_valid_role_kind_status,
             check: @new_constraint
           )
  end

  def down do
    execute(
      "ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_valid_role_kind_status"
    )

    create constraint(:conversation_messages, :conversation_messages_valid_role_kind_status,
             check: @old_constraint
           )
  end
end
