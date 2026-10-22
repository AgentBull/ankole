defmodule Ankole.Sessions.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Sessions.SessionWorkspace)
    resource(Ankole.Sessions.RoundState)
    resource(Ankole.Sessions.Receipts)
    resource(Ankole.Sessions.AmbientJudgment)
  end
end
