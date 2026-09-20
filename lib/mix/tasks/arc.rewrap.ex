defmodule Mix.Tasks.Arc.Rewrap do
  @shortdoc "Re-encrypts every stored secret under the current ARC_ENCRYPTION_KEY"
  @moduledoc """
  Rotating the encryption key:

  1. Generate a new key (`mix arc.gen.keys`).
  2. Set it as `ARC_ENCRYPTION_KEY` and move the old one to `ARC_ENCRYPTION_KEY_RETIRED`.
  3. Restart every node. Old rows still decrypt with the retired key.
  4. Run this task once (or `bin/arc eval "Arc.Release.rewrap()"` in a release):

         mix arc.rewrap

  5. Remove `ARC_ENCRYPTION_KEY_RETIRED` and restart.

  Prints the number of rows rewritten per table.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    for {table, count} <- Arc.Release.rewrap() do
      Mix.shell().info("#{table}: #{count} rows re-encrypted")
    end
  end
end
