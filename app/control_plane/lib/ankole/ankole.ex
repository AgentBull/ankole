defmodule Ankole do
  @moduledoc """
  Namespace root for the control-plane domain contexts.

  Ankole is an AgentOS: this control plane owns Principals/AuthZ, AppConfigure,
  the plugin registry, Signals intake, the Session runtime, and the
  operator web shell. Each concern lives in its own context module
  (`Ankole.Principals`, `Ankole.Plugins`, `Ankole.Sessions.Queue`, ...); this bare
  module only anchors the namespace and carries no behavior.
  """
end
