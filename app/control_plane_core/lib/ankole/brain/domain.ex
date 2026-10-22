defmodule Ankole.Brain.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Brain.Schemas.Object)
    resource(Ankole.Brain.Schemas.Chunk)
    resource(Ankole.Brain.Schemas.ObjectVersion)
    resource(Ankole.Brain.Schemas.Claim)
    resource(Ankole.Brain.Schemas.Source)
    resource(Ankole.Brain.Schemas.Timeline)
    resource(Ankole.Brain.Schemas.Link)
    resource(Ankole.Brain.Schemas.Tag)
    resource(Ankole.Brain.Schemas.ObjectAlias)
    resource(Ankole.Brain.Schemas.SlugAlias)
    resource(Ankole.Brain.Schemas.SchemaSuggestion)
    resource(Ankole.Brain.Schemas.MergeSuggestion)
    resource(Ankole.Brain.Schemas.Contradiction)
    resource(Ankole.Brain.Schemas.SchemaPack)
    resource(Ankole.Brain.Schemas.SchemaType)
    resource(Ankole.Brain.Schemas.SchemaLinkType)
    resource(Ankole.Brain.Schemas.SchemaCalibrationDomain)
    resource(Ankole.Brain.Schemas.TakeDomainAssignment)
  end
end
