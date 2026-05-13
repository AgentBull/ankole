defmodule BullX.Principals do
  @moduledoc """
  Principal identity and AuthN boundary.

  Public callers resolve, create, activate, and authenticate durable BullX
  subjects through this facade instead of composing schema modules directly.
  """

  alias BullX.Principals.AuthN

  defdelegate get_principal(id), to: AuthN
  defdelegate update_principal_status(principal_or_id, status), to: AuthN
  defdelegate disable_principal(principal_or_id), to: AuthN
  defdelegate create_human(attrs), to: AuthN
  defdelegate create_agent(attrs), to: AuthN
  defdelegate resolve_channel_actor(adapter, channel_id, external_id), to: AuthN
  defdelegate match_or_create_human_from_channel(input), to: AuthN
  defdelegate match_or_create_human_from_login_subject(input), to: AuthN
  defdelegate create_activation_code(created_by_principal, metadata \\ %{}), to: AuthN
  defdelegate consume_activation_code(plaintext_code, input), to: AuthN
  defdelegate create_or_refresh_bootstrap_activation_code(), to: AuthN
  defdelegate bootstrap_activation_code_pending?(), to: AuthN
  defdelegate verify_bootstrap_activation_code(plaintext), to: AuthN
  defdelegate bootstrap_activation_code_valid_for_hash?(code_hash), to: AuthN
  defdelegate issue_login_auth_code(adapter, channel_id, external_id), to: AuthN
  defdelegate consume_login_auth_code(plaintext_code), to: AuthN
end
