defmodule Arc.Vault do
  @moduledoc """
  Encryption at rest for secrets stored in Postgres (app secrets, encryption master
  keys, webhook secrets). Keyed by `ARC_ENCRYPTION_KEY`; see `config/runtime.exs`.
  """
  use Cloak.Vault, otp_app: :arc
end
