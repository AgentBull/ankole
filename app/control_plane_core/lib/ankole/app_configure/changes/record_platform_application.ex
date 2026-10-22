defmodule Ankole.AppConfigure.Changes.RecordPlatformApplication do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def atomic(changeset, _opts, _context) do
    application = Ash.Changeset.get_argument(changeset, :application)

    {:atomic,
     %{
       value:
         expr(
           fragment(
             "? || jsonb_build_object('platform_application', ?::text)",
             value,
             ^application
           )
         )
     }}
  end
end
