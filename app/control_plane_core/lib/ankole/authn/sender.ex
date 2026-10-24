defmodule Ankole.Authn.Sender do
  @moduledoc "Delivers an authentication challenge through the configured channel."
  @callback send(atom(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
end
