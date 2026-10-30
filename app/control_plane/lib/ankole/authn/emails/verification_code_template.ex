defmodule Ankole.Authn.Emails.VerificationCodeTemplate do
  @moduledoc "Compile-time MJML template for email verification codes."

  require EEx

  @template Path.join(__DIR__, "verification_code_template.mjml.eex")
  @external_resource @template
  @external_resource Path.join(__DIR__, "layout.mjml.eex")

  EEx.function_from_string(
    :defp,
    :html,
    Ankole.Authn.Emails.Layout.compile_file(@template),
    [:assigns],
    engine: Phoenix.HTML.Engine
  )

  def render(assigns), do: assigns |> html() |> Phoenix.HTML.safe_to_string()
end
