defmodule Ankole.Authn.Emails.Layout do
  @moduledoc "Shared MJML card layout for site authentication and invitation emails."

  use MjmlEEx.Layout, mjml_layout: "layout.mjml.eex"
end
