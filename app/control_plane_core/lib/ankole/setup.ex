defmodule Ankole.Setup do
  @moduledoc """
  The domain of the first-setup operation.

  `Ankole.Setup.Completion` is the entry point. The domain lists the
  operations resource that owns the completion transaction.
  """
  use Ankole.Ash.Domain

  resources do
    resource(Ankole.Setup.Operations)
  end
end
