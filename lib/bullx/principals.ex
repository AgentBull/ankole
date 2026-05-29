defmodule BullX.Principals do
  @moduledoc """
  Principal identity and AuthN boundary.

  ## Why this module exists

  In an OpenClaw / Hermes-Agent / Claude Code-style harness, the underlying
  identity model is implicit: there is one user (the operator), the agent
  acts on that user's behalf, and tool authorization is configured per-agent
  ("which tools is the assistant allowed to call"). Multi-user support is a
  separately requested feature, typically bolted on with web-layer RBAC.

  BullX has one Installation-level operating domain. Inside that domain, a
  **Principal** is the stable, durable identity of any subject that can act,
  be acted upon, or hold authority: humans, AI Agents, and (in future) other
  automated subjects all share the same row shape. Every Conversation,
  Message, tool invocation, Budget charge, ApprovalRequest, and routing
  decision references one or more Principals — so the answer to "who did
  this?" and "who is authorized to do that?" is a database fact, not a
  runtime convention.

  Concretely, an `AIAgent` Receiver is itself a Principal (with an Agent
  extension row carrying its profile, soul, mission, toolsets, etc.), and so
  is every human reachable via a channel adapter or a login flow. This means
  ACL checks, audit trails, and human-in-the-loop approvals operate on a
  uniform identity surface — there is no "agent permissions" subsystem
  separate from "user permissions".

  ## Internal contract

  Public callers resolve, create, activate, and authenticate durable BullX
  subjects through this facade instead of composing schema modules directly.
  """

  alias BullX.Principals.AuthN

  defdelegate get_principal(uid), to: AuthN
  defdelegate setup_required?(), to: AuthN
  defdelegate update_principal_status(principal_or_uid, status), to: AuthN
  defdelegate disable_principal(principal_or_uid), to: AuthN
  defdelegate create_human(attrs), to: AuthN
  defdelegate create_agent(attrs), to: AuthN
  defdelegate update_agent(principal_or_uid, attrs), to: AuthN
  defdelegate list_active_agents(), to: AuthN
  defdelegate resolve_channel_actor(adapter, channel_id, external_id), to: AuthN
  defdelegate match_or_create_human_from_channel(input), to: AuthN
  defdelegate ensure_human_from_channel_actor(input), to: AuthN
  defdelegate channel_identity_verified?(identity), to: AuthN
  defdelegate match_or_create_human_from_login_subject(input), to: AuthN
  defdelegate root_init_with_bootstrap_code(plaintext_code, input), to: AuthN
  defdelegate create_or_refresh_bootstrap_activation_code(), to: AuthN
  defdelegate verify_bootstrap_activation_code_for_setup(plaintext), to: AuthN
  defdelegate bootstrap_activation_code_valid_for_hash?(code_hash), to: AuthN
  defdelegate issue_login_auth_code(adapter, channel_id, external_id), to: AuthN
  defdelegate consume_login_auth_code(plaintext_code), to: AuthN

  defdelegate login_provider_options(server \\ BullX.Plugins.Registry),
    to: BullX.Principals.LoginProviders,
    as: :provider_options

  @doc """
  URL of the web login page, derived from the configured Phoenix endpoint.

  Used by IM channel adapters to embed a sign-in link in chat replies.
  """
  @spec web_login_url() :: String.t()
  def web_login_url do
    BullXWeb.Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/sessions/new")
  end
end
