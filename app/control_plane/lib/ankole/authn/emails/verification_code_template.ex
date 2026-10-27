defmodule Ankole.Authn.Emails.VerificationCodeTemplate do
  @moduledoc "Compile-time MJML template for email verification codes."

  use MjmlEEx,
    mjml_template: "verification_code_template.mjml.eex",
    layout: Ankole.Authn.Emails.Layout,
    mode: :compile
end
