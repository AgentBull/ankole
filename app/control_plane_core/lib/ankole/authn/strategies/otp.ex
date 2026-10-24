defmodule Ankole.Authn.Strategies.Otp do
  @moduledoc "A site-scoped, directly addressable one-time-code strategy."
  defstruct name: :email_otp,
            scope: :site,
            provider_id: "email_otp",
            sender: nil,
            __spark_metadata__: nil
end
