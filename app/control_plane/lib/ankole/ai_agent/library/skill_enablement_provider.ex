defmodule Ankole.AIAgent.Library.SkillEnablementProvider do
  @moduledoc """
  Adapter contract for projecting one builtin Skill execution profile into
  effective Agent Library enablement.

  The Library owns how a projection combines with persisted per-Agent flags.
  Implementations own only the external facts needed to choose automatic or
  manual mode for their declared execution profile.
  """

  defmodule Context do
    @moduledoc """
    Library-owned context supplied to one enablement provider resolution.
    """

    @enforce_keys [:agent_uid, :repo]
    defstruct [:agent_uid, :repo]

    @type t :: %__MODULE__{
            agent_uid: String.t(),
            repo: module()
          }
  end

  @type mode :: :manual | {:projected, boolean()}

  @callback resolve(Context.t()) :: {:ok, mode()} | {:error, term()}
end
