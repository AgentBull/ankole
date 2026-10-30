defmodule Ankole.Authn.Emails.InvitationTemplate do
  @moduledoc "Compile-time MJML template for Pod invitation emails."

  require EEx

  @template Path.join(__DIR__, "invitation_template.mjml.eex")
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
