defmodule Ankole.Signals.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Signals.Binding do
      define(:get_binding, action: :read, get_by: [:agent_uid, :name], not_found_error?: false)
      define(:list_bindings, action: :read)
      define(:put_binding, action: :put)
      define(:disable_binding, action: :disable)
      define(:remove_binding, action: :remove)
    end

    resource Ankole.Signals.WebhookEndpoint do
      define(:get_webhook_endpoint, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_webhook_endpoints, action: :read)
    end

    resource Ankole.Signals.Signal do
      define(:get_signal, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_signals, action: :read)
      define(:accept_signal, action: :accept)
      define(:refund_attempt_signal, action: :refund_attempt)
      define(:revise_input_signal, action: :revise_input)
      define(:update_metadata_signal, action: :update_metadata)
      define(:reauthorize_signal, action: :reauthorize)
      define(:remove_signal, action: :remove)
    end
  end
end
