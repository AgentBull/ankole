defmodule Ankole.Plugins.LinearAdapter.Tools do
  @moduledoc "The supported Linear MCP contract. Upstream catalog changes require an explicit contract update."
  alias Ankole.Connectors.ToolSpec

  def tools do
    [
      tool(
        "get_issue",
        "Read an issue by UUID or identifier.",
        ["id"],
        strings(~w(id)) ++ booleans(~w(includeRelations)),
        :issue
      ),
      tool(
        "list_issues",
        "Find issues with cursor pagination.",
        [],
        strings(
          ~w(cursor query team assignee state label project cycle parentId createdAt updatedAt)
        ) ++ integers(~w(limit priority)) ++ booleans(~w(includeArchived)),
        {:list, :issue}
      ),
      tool(
        "save_issue",
        "Create or update an issue. Supply id to update; supply title and team to create.",
        [],
        strings(
          ~w(id title description team assignee state project cycle milestone parentId dueDate duplicateOf)
        ) ++ arrays(~w(labels blocks blockedBy relatedTo)) ++ integers(~w(priority estimate)),
        :issue,
        write: true,
        create_fields: ~w(title team)
      ),
      tool(
        "list_projects",
        "List projects with cursor pagination.",
        [],
        strings(~w(cursor query team state lead)) ++
          integers(~w(limit)) ++ booleans(~w(includeArchived)),
        {:list, :project}
      ),
      tool(
        "get_project",
        "Read a project by UUID, name, or slug.",
        ["query"],
        strings(~w(query)) ++ booleans(~w(includeMembers includeMilestones includeResources)),
        :project
      ),
      tool(
        "save_project",
        "Create or update a project. Supply id to update; supply name and teams to create.",
        [],
        strings(~w(id name description content state lead startDate targetDate)) ++
          arrays(~w(teams members labels)) ++ integers(~w(priority)),
        :project,
        write: true,
        create_fields: ~w(name teams)
      ),
      tool(
        "list_cycles",
        "List a team's cycles.",
        ["teamId"],
        strings(~w(teamId)) ++
          [{"type", %{"type" => "string", "enum" => ~w(current previous next)}}],
        {:list, :cycle}
      ),
      tool(
        "list_comments",
        "List comments for one issue, project, initiative, or project update.",
        [],
        strings(~w(issue project initiative projectUpdate cursor)) ++ integers(~w(limit)),
        {:list, :comment}
      ),
      tool(
        "save_comment",
        "Create or update a comment; use id for an edit and a parent resource for a new comment.",
        ["body"],
        strings(~w(id body issue project initiative projectUpdate parentId)),
        :comment,
        write: true
      ),
      tool("delete_comment", "Delete a comment by ID.", ["id"], strings(~w(id)), :result,
        write: true,
        destructive: true
      ),
      tool(
        "list_teams",
        "Find teams in the connected workspace.",
        [],
        strings(~w(query cursor)) ++ integers(~w(limit)),
        {:list, :team}
      ),
      tool("get_team", "Read a team by ID or name.", ["query"], strings(~w(query)), :team),
      tool(
        "list_issue_labels",
        "List workspace or team issue labels.",
        [],
        strings(~w(name team cursor)) ++ integers(~w(limit)),
        {:list, :label}
      ),
      tool(
        "create_issue_label",
        "Create an issue label.",
        ["name"],
        strings(~w(name description color team parent)),
        :label,
        write: true
      ),
      tool(
        "list_issue_statuses",
        "List the workflow states of a team.",
        ["team"],
        strings(~w(team)),
        {:list, :status}
      ),
      tool(
        "get_issue_status",
        "Read a workflow state.",
        ["id"],
        strings(~w(id name team)),
        :status
      ),
      tool(
        "list_users",
        "Find members of the connected workspace.",
        [],
        strings(~w(query cursor)) ++ integers(~w(limit)),
        {:list, :user}
      ),
      tool(
        "get_user",
        "Read a workspace member by ID, name, email, or me.",
        ["query"],
        strings(~w(query)),
        :user
      )
    ]
  end

  defp tool(name, description, required, fields, output, opts \\ []) do
    input = %{
      "type" => "object",
      "properties" => Map.new(fields),
      "required" => required,
      "additionalProperties" => false
    }

    input =
      if opts[:create_fields],
        do:
          Map.put(input, "anyOf", [%{"required" => ["id"]}, %{"required" => opts[:create_fields]}]),
        else: input

    %ToolSpec{
      toolkit: "linear",
      name: name,
      description: description,
      input_schema: input,
      output_schema: %{
        "type" => "object",
        "properties" => %{"result" => output(output)},
        "required" => ["result"]
      },
      operation: name,
      upstream_auth: :adaptive_token,
      scopes: if(opts[:write], do: ["write"], else: ["read"]),
      annotations: ToolSpec.annotations(opts[:write] != true, false, opts[:destructive] == true)
    }
  end

  defp output({:list, kind}) do
    %{
      "type" => "object",
      "properties" => %{
        "items" => %{"type" => "array", "items" => output(kind)},
        "has_next_page" => %{"type" => "boolean"},
        "cursor" => %{"type" => ["string", "null"]}
      },
      "required" => ["items", "has_next_page", "cursor"]
    }
  end

  defp output(kind) do
    fields =
      case kind do
        :issue ->
          ~w(id identifier title description url status assignee project team priority createdAt updatedAt)

        :project ->
          ~w(id name description content url status lead startDate targetDate)

        :cycle ->
          ~w(id name number startsAt endsAt)

        :comment ->
          ~w(id body createdAt updatedAt)

        :team ->
          ~w(id name key description)

        :label ->
          ~w(id name description color)

        :status ->
          ~w(id name type color)

        :user ->
          ~w(id name displayName email)

        :result ->
          ~w(success)
      end

    %{
      "type" => "object",
      "properties" =>
        Map.new(fields, fn name ->
          {name,
           cond do
             name == "success" ->
               %{"type" => "boolean"}

             name in ~w(priority number) ->
               %{"type" => ["number", "null"]}

             name in ~w(assignee project team lead status) ->
               %{"type" => ["object", "string", "null"]}

             true ->
               %{"type" => ["string", "null"]}
           end}
        end)
    }
  end

  defp strings(fields), do: Enum.map(fields, &{&1, %{"type" => ["string", "null"]}})

  defp arrays(fields),
    do: Enum.map(fields, &{&1, %{"type" => "array", "items" => %{"type" => "string"}}})

  defp integers(fields), do: Enum.map(fields, &{&1, %{"type" => "integer"}})
  defp booleans(fields), do: Enum.map(fields, &{&1, %{"type" => "boolean"}})
end
