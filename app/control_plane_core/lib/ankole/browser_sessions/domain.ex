defmodule Ankole.BrowserSessions.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ankole.BrowserSessions.Session)
    resource(Ankole.BrowserSessions.Authentication)
    resource(Ankole.BrowserSessions.LoginTransaction)
    resource(Ankole.BrowserSessions.PodAuthentication)
  end
end
