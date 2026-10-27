defmodule Ankole.Authn.Emails.InvitationTemplate do
  @moduledoc "Compile-time MJML template for Pod invitation emails."

  use MjmlEEx,
    mjml_template: "invitation_template.mjml.eex",
    layout: Ankole.Authn.Emails.Layout,
    mode: :compile
end
