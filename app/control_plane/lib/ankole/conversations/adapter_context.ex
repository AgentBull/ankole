defmodule Ankole.Conversations.AdapterContext do
  @moduledoc """
  Binding runtime context and helper access handed to a signal adapter.
  """

  alias Ankole.Conversations.ActionCards
  alias Ankole.Principals

  @enforce_keys [:binding_id, :agent_uid, :binding_name, :adapter, :user_name]
  defstruct [:binding_id, :agent_uid, :binding_name, :adapter, :user_name]

  @type t :: %__MODULE__{
          binding_id: String.t(),
          agent_uid: String.t() | nil,
          binding_name: String.t(),
          adapter: String.t(),
          user_name: String.t()
        }

  @doc """
  Builds the adapter-facing context for one configured signal binding.

  The context carries only binding identity and lightweight helper access.
  Adapters submit normalized provider facts through
  `Ankole.Conversations.Observe`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    %__MODULE__{
      binding_id: fetch!(attrs, :binding_id),
      agent_uid: fetch!(attrs, :agent_uid),
      binding_name: fetch!(attrs, :binding_name),
      adapter: fetch!(attrs, :adapter),
      # user_name is the human-facing display label; default it to the adapter id
      # so an adapter that doesn't supply one still has something to show.
      user_name: fetch(attrs, :user_name) || fetch!(attrs, :adapter)
    }
  end

  @doc """
  Observes a provider-side subject and links it to a human principal.

  The binding name becomes the default provider so adapters do not have to repeat
  it for every subject observation.
  """
  @spec observe_platform_subject(t(), map()) :: {:ok, map()} | {:error, term()}
  def observe_platform_subject(%__MODULE__{} = context, attrs) when is_map(attrs) do
    attrs
    |> put_default(:provider, context.binding_name)
    |> Principals.upsert_platform_subject_human()
  end

  @doc "Runs all chat consumers in order and collects their results."
  @spec dispatch_chat([map()], (map() -> term())) :: {:ok, [term()]} | {:error, term()}
  def dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> Ankole.Attrs.collect_results()
  end

  @doc "Observes a platform subject and returns its human Principal UID."
  @spec observe_platform_subject_uid(t(), map()) :: {:ok, String.t()} | {:error, term()}
  def observe_platform_subject_uid(context, attrs) do
    case observe_platform_subject(context, attrs) do
      {:ok, %{principal: principal}} -> {:ok, principal.uid}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns true when `interaction_id` addresses an Action Card callback."
  @spec action_card_interaction_id?(term()) :: boolean()
  defdelegate action_card_interaction_id?(interaction_id), to: ActionCards

  @doc """
  Resolves the Principal UID for an interactive callback operator.

  Action Card clicks resolve existing Principals without auto-provisioning new
  members (`{:ok, uid | nil}`) so unmapped clickers receive an explicit Action
  Card rejection receipt. Non-Action-Card interactions either require a mapped
  subject (`:reject`, the default for consumer channels) or invoke `fallback.()`
  to observe an enterprise directory member.
  """
  @spec resolve_action_operator(
          String.t(),
          String.t() | [String.t()],
          term(),
          :reject | (-> {:ok, String.t()} | {:error, term()})
        ) :: {:ok, String.t() | nil} | {:error, term()}
  def resolve_action_operator(provider, external_ids, interaction_or_value, fallback \\ :reject) do
    interaction_id =
      if is_map(interaction_or_value),
        do: interaction_or_value["interactionId"],
        else: interaction_or_value

    candidates =
      external_ids
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if action_card_interaction_id?(interaction_id) do
      {:ok, resolve_first_subject_uid(provider, candidates)}
    else
      case fallback do
        :reject ->
          case resolve_first_subject_uid(provider, candidates) do
            uid when is_binary(uid) -> {:ok, uid}
            nil -> {:error, :not_found}
          end

        observe_fun when is_function(observe_fun, 0) ->
          observe_fun.()
      end
    end
  end

  defp resolve_first_subject_uid(provider, candidates) do
    Enum.find_value(candidates, fn id ->
      case Principals.resolve_platform_subject_uid(provider, id) do
        {:ok, uid} -> uid
        _ -> nil
      end
    end)
  end

  defp put_default(attrs, key, value) do
    Map.put_new(attrs, key, value)
  end

  defp fetch(attrs, key) do
    if Keyword.keyword?(attrs), do: Keyword.get(attrs, key), else: Map.get(attrs, key)
  end

  defp fetch!(attrs, key) do
    if Keyword.keyword?(attrs), do: Keyword.fetch!(attrs, key), else: Map.fetch!(attrs, key)
  end
end
