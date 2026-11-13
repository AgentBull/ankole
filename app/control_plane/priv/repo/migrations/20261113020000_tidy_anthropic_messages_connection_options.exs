defmodule Ankole.Repo.Migrations.TidyAnthropicMessagesConnectionOptions do
  use Ecto.Migration

  # The kernel chooses the `anthropic-version` header from the target model, so
  # Claude and Xiaomi MiMo connections no longer declare a version setting.
  # Xiaomi MiMo serves one Messages path and documents no beta header, so its
  # path and beta settings go too. The Console stored the former defaults on
  # each connection it created, and the write path rejects unknown keys, so
  # those keys leave every stored row. An operator who must pin a version
  # sends it through the connection's `headers` setting.
  #
  # Xiaomi MiMo's billing plan accepted free text, and every value other than
  # `token_plan` meant pay as you go. It is now a closed choice, so a stored
  # value outside the choice is dropped and the row keeps paying as it goes.
  def up do
    execute("""
    UPDATE ai_gateway_providers
    SET connection_options = connection_options - 'anthropic_version'
    WHERE provider_kind = 'claude'
      AND jsonb_typeof(connection_options) = 'object'
      AND connection_options ? 'anthropic_version'
    """)

    execute("""
    UPDATE ai_gateway_providers
    SET connection_options =
      connection_options - 'anthropic_version' - 'anthropic_beta' - 'messages_path'
    WHERE provider_kind = 'xiaomi_mimo'
      AND jsonb_typeof(connection_options) = 'object'
      AND connection_options ?| array['anthropic_version', 'anthropic_beta', 'messages_path']
    """)

    execute("""
    UPDATE ai_gateway_providers
    SET connection_options = connection_options - 'xiaomi_mimo_billing_plan'
    WHERE provider_kind = 'xiaomi_mimo'
      AND jsonb_typeof(connection_options) = 'object'
      AND connection_options ? 'xiaomi_mimo_billing_plan'
      AND coalesce(connection_options->>'xiaomi_mimo_billing_plan', '') NOT IN
        ('pay_as_you_go', 'token_plan', 'token_plan_sgp', 'token_plan_ams')
    """)
  end

  # The removed settings no longer exist, so restoring them would write values
  # the write path rejects as unknown keys, and a dropped billing plan meant pay
  # as you go both before and after.
  def down, do: :ok
end
