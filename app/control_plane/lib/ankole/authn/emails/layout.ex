defmodule Ankole.Authn.Emails.Layout do
  @moduledoc "Shared MJML card layout for site authentication and invitation emails."

  @layout Path.join(__DIR__, "layout.mjml.eex")
  @external_resource @layout
  @source File.read!(@layout)

  @doc "Compiles a shared-layout email into an HTML EEx template at build time."
  def compile_file(path) do
    mjml = String.replace(@source, "<%= @inner_content %>", File.read!(path))

    # These templates interpolate assigns only. Keep them out of the MJML parser;
    # Phoenix.HTML.Engine escapes their values when the compiled email renders.
    mjml = Regex.replace(~r/<%=\s*@(\w+)\s*%>/, mjml, "__ANKOLE_EMAIL_\\1__")
    {:ok, html} = Mjml.to_html(mjml)
    Regex.replace(~r/__ANKOLE_EMAIL_(\w+)__/, html, "<%= @\\1 %>")
  end
end
