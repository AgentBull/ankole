defmodule Ankole.AIAgent.Operations do
  @moduledoc """
  The generic actions that change the AIAgent object in the Agent options.

  Principals owns the Agent row. This domain owns `options["ai_agent"]`: the
  model profiles, the Provider-hosted capabilities, and the token quota. Each
  action locks the Agent row and writes the new options in one transaction.
  The resource keeps no rows.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIAgent, operations: true

  alias Ankole.AIAgent.{ModelProfiles, TokenQuota}

  actions do
    action :put_token_quota, :term do
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:attrs, :term, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> TokenQuota.put_locked() |> Ankole.Errors.wrap()
      end)
    end

    action :delete_token_quota, :term do
      allow_nil?(true)
      argument(:agent_uid, :string, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> TokenQuota.delete_locked() |> Ankole.Errors.wrap()
      end)
    end

    action :reset_token_quota, :term do
      argument(:agent_uid, :string, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> TokenQuota.reset_locked() |> Ankole.Errors.wrap()
      end)
    end

    action :put_model_profile, :term do
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:profile, :term, allow_nil?: false)
      argument(:attrs, :term)

      run(fn input, _context ->
        input.arguments |> ModelProfiles.put_profile_locked() |> Ankole.Errors.wrap()
      end)
    end

    action :put_provider_hosted_capabilities, :term do
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> ModelProfiles.put_provider_hosted_locked() |> Ankole.Errors.wrap()
      end)
    end
  end
end
