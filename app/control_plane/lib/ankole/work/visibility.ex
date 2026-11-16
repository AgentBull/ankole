defmodule Ankole.Work.Visibility do
  @moduledoc """
  Applies human standalone visibility rules to durable work queries across
  BackgroundAgentJobs and Workflow runs.
  """

  require Ash.Query

  def filter_standalone_visibility(query, scope) do
    uid = scope.uid

    query =
      if scope.foreign_pa_uids == [] do
        query
      else
        Ash.Query.filter(query, is_nil(agent_uid) or agent_uid not in ^scope.foreign_pa_uids)
      end

    query =
      if scope.live_cron_sessions == [] do
        query
      else
        Ash.Query.filter(query, owner_session_id not in ^scope.live_cron_sessions)
      end

    if scope.visible_room_ids == [] do
      Ash.Query.filter(
        query,
        (fragment("starts_with(?, 'pod_job:')", owner_session_id) and human_uid == ^uid) or
          (fragment("starts_with(?, 'routine:')", owner_session_id) and human_uid == ^uid)
      )
    else
      Ash.Query.filter(
        query,
        owner_session_id in ^scope.visible_conv_sessions or
          (fragment("starts_with(?, 'pod_job:')", owner_session_id) and human_uid == ^uid) or
          (fragment("starts_with(?, 'routine:')", owner_session_id) and
             (human_uid == ^uid or
                fragment(
                  "(? ->> 'conversation_id') = ANY(?::text[])",
                  reply_route,
                  ^scope.visible_room_ids
                )))
      )
    end
  end
end
