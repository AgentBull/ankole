defmodule Ankole.Conversations.Delivery.ClarifyPrompt do
  @moduledoc """
  Extracts a turn-ending `clarify` tool result into portable interactive output.
  """

  alias Ankole.Ecto.JSONPayload
  alias Ankole.I18n
  alias Ankole.Conversations.Delivery.ClarifyForm
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.ToolOutput

  @tool_name "clarify"

  @spec from_response_items(term()) :: {:ok, map() | nil} | {:error, term()}
  def from_response_items(items),
    do: ToolOutput.last(items, @tool_name, &from_output/2)

  def from_output(%{"tool" => @tool_name} = output, call_id) do
    with {:ok, question} <- required_text(output, :question),
         {:ok, choices} <- normalize_choices(Map.get(output, "choices", [])),
         {:ok, fields} <- normalize_fields(Map.get(output, "fields")) do
      fallback = fallback_text(question, choices, fields)

      {:ok,
       %{
         "fallback_visible_text" => fallback,
         "interactive_output" =>
           %{
             "title" => I18n.t("conversations.delivery.clarify.title"),
             "body" => question,
             "fallback_visible_text" => fallback,
             "interaction_id" => "clarify:#{call_id}",
             "control_id" => "clarify-choice",
             "version" => 1,
             "free_input" => true,
             "free_input_hint" => I18n.t("conversations.delivery.clarify.free_input_hint"),
             "choices" => choices
           }
           |> Ankole.Attrs.maybe_put("fields", if(fields != [], do: fields))
       }}
    else
      {:error, reason} -> {:error, {:invalid_clarify_output, call_id, reason}}
    end
  end

  def from_output(_output, _call_id), do: :ignore

  @doc """
  Returns the durable form definition of a clarify interactive output, keyed
  by its interaction ID, or an empty map for an ordinary clarify.
  """
  @spec forms(map()) :: %{String.t() => map()}
  def forms(%{"interaction_id" => id, "body" => question, "fields" => [_ | _] = fields}),
    do: %{id => %{"question" => question, "fields" => fields}}

  def forms(_interactive_output), do: %{}

  @doc """
  Builds the line that links an external channel to the Pod form dialog.

  The link names the native interaction ID (`<source_signal_id>:<interaction_id>`);
  opening it never answers the question.
  """
  @spec form_link_text(String.t(), map()) :: String.t()
  def form_link_text(source_signal_id, output),
    do:
      I18n.t("conversations.delivery.clarify.form_link", %{
        "url" => form_url(source_signal_id, output)
      })

  @doc "Returns the Pod URL of the standalone form dialog for one clarify."
  @spec form_url(String.t(), map()) :: String.t()
  def form_url(source_signal_id, %{"interaction_id" => interaction_id}),
    do:
      AnkoleWeb.PodURL.current_tenant_url(
        "/?interaction=" <> URI.encode_www_form(source_signal_id <> ":" <> interaction_id)
      )

  defp fallback_text(question, choices, []),
    do:
      ReplyPresentation.clarification_text(
        question,
        choices,
        I18n.t("conversations.delivery.clarify.choice_hint")
      )

  defp fallback_text(question, _choices, fields) do
    labels = Enum.map_join(fields, "\n", &("- " <> &1["label"]))
    Enum.join([question, I18n.t("conversations.delivery.clarify.form_fields"), labels], "\n\n")
  end

  defp normalize_fields(fields) do
    case ClarifyForm.definition(fields) do
      {:ok, fields} -> {:ok, fields}
      {:error, _message} -> {:error, :fields_invalid}
    end
  end

  defp normalize_choices(choices) when is_list(choices) and length(choices) <= 4 do
    choices
    |> Enum.with_index(1)
    |> Enum.map(fn {choice, index} -> normalize_choice(choice, index) end)
    |> Ankole.Attrs.collect_results()
  end

  defp normalize_choices(_choices), do: {:error, :choices_invalid}

  defp normalize_choice(choice, index) do
    with {:ok, choice} <- JSONPayload.normalize_map(choice),
         {:ok, label} <- required_text(choice, :label) do
      {:ok,
       %{
         "id" => "choice-#{index}",
         "label" => label,
         "value" => label
       }
       |> Ankole.Attrs.maybe_put(
         "description",
         Ankole.Attrs.optional_text(Map.get(choice, "description"))
       )}
    end
  end

  defp required_text(map, key),
    do: Ankole.Attrs.required_text(Map.get(map, Atom.to_string(key)), {key, :required})
end
