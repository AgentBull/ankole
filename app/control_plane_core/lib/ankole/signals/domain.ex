defmodule Ankole.Signals.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Signals.Binding)
    resource(Ankole.Signals.WebhookEndpoint)
    resource(Ankole.Signals.Signal)
  end
end
