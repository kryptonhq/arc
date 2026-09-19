defmodule Arc.Encrypted.Binary do
  @moduledoc "Ecto type for a binary column encrypted with `Arc.Vault`."
  use Cloak.Ecto.Binary, vault: Arc.Vault
end
