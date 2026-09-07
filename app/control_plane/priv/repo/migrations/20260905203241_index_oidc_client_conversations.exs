defmodule Ankole.Repo.Migrations.IndexOidcClientConversations do
  use Ecto.Migration

  def change do
    create index(:ai_gateway_messages, ["(metadata->>'oidc_client_id')", :conversation_id, :id],
             name: :ai_gateway_messages_oidc_client_conversation_index,
             where: "metadata->>'oidc_client_id' IS NOT NULL AND type = 'message'"
           )
  end
end
