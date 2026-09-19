defmodule Mix.Tasks.Arc.Gen.Keys do
  @shortdoc "Prints freshly generated SECRET_KEY_BASE and ARC_ENCRYPTION_KEY values"
  @moduledoc """
  Generates the two server keys Arc needs and prints them as environment variable
  assignments, ready to paste into an `.env` file or a secret store:

      mix arc.gen.keys

  Keep `ARC_ENCRYPTION_KEY` safe. It encrypts every app secret at rest; if it is lost,
  those secrets cannot be recovered and every app must be issued new credentials.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("""
    SECRET_KEY_BASE=#{:crypto.strong_rand_bytes(64) |> Base.encode64(padding: false) |> binary_part(0, 64)}
    ARC_ENCRYPTION_KEY=#{:crypto.strong_rand_bytes(32) |> Base.encode64()}
    """)
  end
end
