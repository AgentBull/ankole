defmodule Ankole.Repo.Migrations.NormalizeRefreshTokenContext do
  use Ecto.Migration

  def up do
    drop constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_context)

    execute("""
    UPDATE oidc_refresh_tokens
    SET context = (context - 'subject' - 'client_id' - 'scope') ||
      jsonb_build_object('claims', (context->'claims') - 'session_id')
    """)

    create constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_context_object,
             check: "jsonb_typeof(context) = 'object'"
           )
  end

  def down do
    drop constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_context_object)

    execute("""
    UPDATE oidc_refresh_tokens
    SET context = context || jsonb_build_object(
      'subject', principal_uid,
      'client_id', client_id::text,
      'scope', string_to_array(scope, ' '),
      'claims', (context->'claims') || jsonb_build_object('session_id', session_id::text)
    )
    """)

    create constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_context,
             check: """
             (jsonb_typeof(context) = 'object'
             AND context ?& ARRAY['subject', 'client_id', 'scope', 'claims']
             AND context->>'subject' = principal_uid
             AND context->>'client_id' = client_id::text
             AND context->'claims'->>'session_id' = session_id::text
             AND context->'scope' = to_jsonb(string_to_array(scope, ' '))) IS TRUE
             """
           )
  end
end
