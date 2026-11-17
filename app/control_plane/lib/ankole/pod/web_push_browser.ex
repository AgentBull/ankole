defmodule Ankole.Pod.WebPushBrowser do
  @moduledoc "The current Pod member's Web Push key and browser subscriptions."

  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Pod.{APIError, WebPush}

  authz do
    scope(:pod)
    allow(:config, check: :guardrail)
    allow(:subscribe, check: :guardrail)
    allow(:unsubscribe, check: :guardrail)
  end

  json_api do
    type("pod_web_push_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :config, :map do
      transaction?(false)
      constraints(fields: [publicKey: [type: :string, allow_nil?: false]])
      run(fn _input, _context -> {:ok, %{publicKey: WebPush.public_key()}} end)
    end

    action :subscribe, :map do
      transaction?(false)
      argument(:endpoint, :string, allow_nil?: false, constraints: [max_length: 2048])
      argument(:p256dh, :string, allow_nil?: false, constraints: [max_length: 256])
      argument(:auth, :string, allow_nil?: false, constraints: [max_length: 64])
      argument(:userAgent, :string, allow_nil?: true, constraints: [max_length: 1024])
      constraints(fields: [subscribed: [type: :boolean, allow_nil?: false]])

      run(fn input, context ->
        WebPush.subscribe(context.actor, input.arguments) |> APIError.result()
      end)
    end

    action :unsubscribe, :map do
      transaction?(false)
      argument(:endpoint, :string, allow_nil?: false, constraints: [max_length: 2048])
      constraints(fields: [subscribed: [type: :boolean, allow_nil?: false]])

      run(fn input, context ->
        WebPush.unsubscribe(context.actor, input.arguments.endpoint) |> APIError.result()
      end)
    end
  end
end
