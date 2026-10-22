defmodule Ankole.Ash.Resource do
  @moduledoc """
  Declares the tenant and transaction contracts for a durable resource.

  `Ankole.Ash.Transformers.CallerTransaction` gives the transaction owner of
  each action. A generic action must be the top-level call
  (`Ankole.Ash.TopLevel`) and can publish after its commit with
  `after_commit/1`.
  """

  defmacro __using__(opts) do
    {tenancy, opts} = Keyword.pop!(opts, :tenancy)
    {tenant_in_primary_key, opts} = Keyword.pop(opts, :tenant_in_primary_key, false)

    unless tenancy in [:tenant, :site],
      do: raise(ArgumentError, "resource tenancy must be :tenant or :site")

    if tenant_in_primary_key and tenancy != :tenant,
      do: raise(ArgumentError, "site resources cannot include tenant_id in their primary key")

    opts =
      opts
      |> Keyword.put_new(:domain, nil)
      |> Keyword.put_new(:data_layer, AshPostgres.DataLayer)
      |> Keyword.update(:extensions, [Ankole.Ash.Extension], &[Ankole.Ash.Extension | &1])

    quote do
      use Ash.Resource, unquote(opts)

      import Ankole.Ash.Resource,
        only: [
          create_if_absent: 2,
          create_if_absent: 3,
          in_tx_update: 2,
          atomic_in_tx_update: 2,
          after_commit: 1
        ]

      def __tenancy__, do: unquote(tenancy)
      @persist {:ankole_tenancy, unquote(tenancy)}

      preparations do
        prepare(Ankole.Ash.TopLevel, on: [:action])
      end

      if unquote(tenancy) == :tenant do
        attributes do
          attribute :tenant_id, Ankole.Ash.Types.UUIDv7 do
            allow_nil?(false)
            primary_key?(unquote(tenant_in_primary_key))
            writable?(false)
            public?(false)
            default(&Ankole.Repo.tenant_id/0)
          end
        end

        multitenancy do
          strategy(:attribute)
          attribute(:tenant_id)
          global?(false)
        end

        changes do
          change(Ankole.Ash.DeclaredUpsert, on: [:create])
        end
      end
    end
  end

  defmacro create_if_absent(name, opts \\ [], do: block) do
    opts = Keyword.validate!(opts, upsert_fields: [])

    quote do
      create unquote(name) do
        upsert?(true)
        upsert_fields(unquote(opts[:upsert_fields]))
        upsert_condition(expr(false))
        return_skipped_upsert?(true)
        unquote(block)
      end
    end
  end

  @doc """
  Declares the publish function that a generic action runs after its commit.

  Use it in an `action` block: `after_commit({Ankole.Signals, :publish_committed})`.
  """
  defmacro after_commit(publish) do
    quote do
      prepare({Ankole.Ash.AfterCommit, publish: unquote(publish)})
    end
  end

  @doc "Declares an update action. New resources use `update` directly."
  defmacro in_tx_update(name, do: block) do
    quote do
      update unquote(name) do
        unquote(block)
      end
    end
  end

  @doc """
  Declares an atomic update action. New resources use `update` with
  `require_atomic?(true)`.
  """
  defmacro atomic_in_tx_update(name, do: block) do
    quote do
      update unquote(name) do
        require_atomic?(true)
        unquote(block)
      end
    end
  end
end
