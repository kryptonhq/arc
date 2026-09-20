defmodule Arc.Admin do
  @moduledoc """
  Dashboard administrators.

  There is one role. An identity is an administrator if the OIDC provider vouches for
  its email (`email_verified`) and the email is in `ARC_ADMIN_EMAILS`. The allowlist
  is re-checked on every request, so removing an email revokes access at once.

  With `ARC_ADMIN_PASSWORD` set there is also a single password administrator: the
  first allowlisted email, or `admin@localhost` when the allowlist is empty. It is the
  same kind of admin user, with the subject `password`, and goes through the same
  session; only the way in differs.
  """
  import Ecto.Query

  alias Arc.Repo
  alias Arc.Admin.AdminUser

  @password_subject "password"
  @default_password_email "admin@localhost"

  @doc "The configured allowlist, lowercased, plus the password admin when enabled."
  def allowed_emails do
    configured =
      Application.get_env(:arc, :oidc, [])
      |> Keyword.get(:admin_emails, [])
      |> Enum.map(&String.downcase(String.trim(&1)))

    case password_email(configured) do
      nil -> configured
      email -> Enum.uniq([email | configured])
    end
  end

  @doc "True when `ARC_ADMIN_PASSWORD` is configured."
  def password_enabled?, do: is_binary(Application.get_env(:arc, :admin_password))

  @doc """
  Checks a submitted password in constant time and, if it matches, signs in the
  password administrator. `{:error, :invalid}` for a wrong password, and for any
  password at all when the mode is off.
  """
  @spec password_sign_in(String.t()) :: {:ok, AdminUser.t()} | {:error, :invalid}
  def password_sign_in(submitted) when is_binary(submitted) do
    case Application.get_env(:arc, :admin_password) do
      expected when is_binary(expected) ->
        if Plug.Crypto.secure_compare(submitted, expected),
          do: {:ok, upsert(password_email(), @password_subject)},
          else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  def password_sign_in(_), do: {:error, :invalid}

  @doc "The password administrator's email, or nil when the mode is off."
  def password_email(configured \\ nil) do
    if password_enabled?() do
      configured =
        configured ||
          Application.get_env(:arc, :oidc, [])
          |> Keyword.get(:admin_emails, [])
          |> Enum.map(&String.downcase(String.trim(&1)))

      List.first(configured) || @default_password_email
    end
  end

  @doc "True if `email` may administer Arc."
  def allowed?(email) when is_binary(email),
    do: String.downcase(String.trim(email)) in allowed_emails()

  def allowed?(_), do: false

  @doc """
  Completes a sign-in from verified ID token claims. Creates the admin user on first
  sign-in and records the login time.
  """
  @spec sign_in(%{optional(String.t()) => term()}) ::
          {:ok, AdminUser.t()} | {:error, :email_missing | :email_unverified | :not_allowed}
  def sign_in(claims) do
    email = claims["email"]
    subject = claims["sub"]

    cond do
      not is_binary(email) or email == "" -> {:error, :email_missing}
      claims["email_verified"] != true -> {:error, :email_unverified}
      not allowed?(email) -> {:error, :not_allowed}
      true -> {:ok, upsert(String.downcase(email), subject)}
    end
  end

  defp upsert(email, subject) do
    now = DateTime.utc_now()

    Repo.insert!(
      %AdminUser{email: email, subject: subject, last_login_at: now},
      on_conflict: [set: [subject: subject, last_login_at: now, updated_at: now]],
      conflict_target: :email,
      returning: true
    )
  end

  @doc "The admin user for a session's email, if the email is still allowlisted."
  def get_by_email(email) when is_binary(email) do
    if allowed?(email),
      do: Repo.one(from a in AdminUser, where: a.email == ^String.downcase(email))
  end

  def get_by_email(_), do: nil

  def list_admins, do: Repo.all(from a in AdminUser, order_by: [asc: a.email])
end
