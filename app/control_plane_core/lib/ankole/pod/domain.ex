defmodule Ankole.Pod.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Pod.DbTable)
    resource(Ankole.Pod.DbField)
    resource(Ankole.Pod.DbView)
    resource(Ankole.Pod.DbRecord)
    resource(Ankole.Pod.Page)
    resource(Ankole.Pod.PageContent)
    resource(Ankole.Pod.PageChange)
    resource(Ankole.Pod.PageUserState)
  end
end
