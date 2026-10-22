defmodule Ankole.Work.Provenance do
  @moduledoc """
  Declares authorization fields and the existing work owner's review contract.

  A work resource uses this module after `use Ankole.Ash.Resource`. It gets
  the read action `:work_across_tenants`: Human work cleanup and review read
  the work of one Human in every tenant through `Ankole.Work.Owner`.
  """

  defmacro __using__(opts) do
    quote do
      import Ankole.Work.Provenance, only: [ash_attributes: 0]

      @work_provenance_fields unquote(
                                Keyword.take(opts, [
                                  :owner_session?,
                                  :source_signal?,
                                  :reply_route?
                                ])
                              )
      def __work_provenance__, do: unquote(opts)

      actions do
        read :work_across_tenants do
          multitenancy(:allow_global)
        end
      end
    end
  end

  defmacro ash_attributes do
    quote do
      attribute(:authorization_kind, :string, default: "review_required", public?: true)
      attribute(:human_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
      attribute(:human_access_version, :integer, public?: true)
      attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)

      if @work_provenance_fields[:owner_session?],
        do: attribute(:owner_session_id, :string, allow_nil?: false, public?: true)

      if @work_provenance_fields[:source_signal?],
        do: attribute(:source_signal_id, Ankole.Ash.Types.UUIDv7, public?: true)

      if @work_provenance_fields[:reply_route?],
        do:
          attribute(:reply_route, Ankole.Ash.Types.JSONMap,
            default: %{},
            allow_nil?: false,
            public?: true
          )
    end
  end
end
