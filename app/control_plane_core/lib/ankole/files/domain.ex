defmodule Ankole.Files.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Files.Schemas.Blob)
    resource(Ankole.Files.Schemas.DriveFile)
  end
end
