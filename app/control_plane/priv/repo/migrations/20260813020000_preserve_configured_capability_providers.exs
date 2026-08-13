defmodule Ankole.Repo.Migrations.PreserveConfiguredCapabilityProviders do
  use Ecto.Migration

  # An Agent now leaves web search and image generation to its language-model
  # Provider unless it says otherwise, so a new Agent needs no capability
  # Provider to search or draw. An Agent that already chose one made that choice
  # explicitly, and the new default would silently move the work to its model, or
  # remove the capability when that model cannot do it. Record the existing
  # choice so behavior is unchanged for them.
  def up do
    Enum.each(up_sqls(), &execute/1)
  end

  # The pre-migration state is "key absent", which is indistinguishable from an
  # operator later choosing the same values. Removing the key would discard that
  # choice, so this migration does not reverse.
  def down, do: :ok

  @doc false
  def up_sqls do
    [
      """
      UPDATE agents
      SET options = jsonb_set(
        options,
        '{ai_agent,provider_hosted}',
        jsonb_strip_nulls(
          jsonb_build_object(
            'web_search',
            CASE WHEN options#>'{ai_agent,models}' ? 'web_search' THEN false ELSE NULL END,
            'image_generate',
            CASE WHEN options#>'{ai_agent,models}' ? 'image_generate' THEN false ELSE NULL END
          )
        ),
        true
      )
      WHERE jsonb_typeof(options#>'{ai_agent,models}') = 'object'
        AND (
          options#>'{ai_agent,models}' ? 'web_search'
          OR options#>'{ai_agent,models}' ? 'image_generate'
        )
        AND options#>'{ai_agent,provider_hosted}' IS NULL
      """
    ]
  end
end
