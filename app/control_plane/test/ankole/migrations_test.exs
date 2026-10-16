defmodule Ankole.MigrationsTest do
  use ExUnit.Case, async: true

  test "the complete file set rejects duplicate versions, names, and modules" do
    root = Path.join(System.tmp_dir!(), "ankole-migrations-#{System.unique_integer([:positive])}")
    first = Path.join(root, "public")
    second = Path.join(root, "private")
    File.mkdir_p!(first)
    File.mkdir_p!(second)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(first, "100_public.exs"), "defmodule PublicMigration do end")
    File.write!(Path.join(second, "200_private.exs"), "defmodule PrivateMigration do end")
    assert :ok == Ankole.Migrations.validate!([first, second])

    for {file, source, kind} <- [
          {"100_collision.exs", "defmodule Collision do end", "version"},
          {"300_public.exs", "defmodule Collision do end", "name"},
          {"300_collision.exs", "defmodule PublicMigration do end", "module"}
        ] do
      path = Path.join(second, file)
      File.write!(path, source)

      assert_raise ArgumentError, ~r/Duplicate migration #{kind}/, fn ->
        Ankole.Migrations.validate!([first, second])
      end

      File.rm!(path)
    end
  end
end
