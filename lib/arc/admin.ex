defmodule Arc.Admin do
  @moduledoc """
  Dashboard administrators.

  There is one role. An identity is an administrator if the OIDC provider vouches for
  its email (`email_verified`) and the email is in `ARC_ADMIN_EMAILS`. The allowlist
  is re-checked on every request, so removing an email revokes access at once.
  """
  import Ecto.Query

  alias Arc.Repo
  alias Arc.Admin.AdminUser

  @doc "The configured allowlist, lowercased."
  def allowed_emails do
    Application.get_env(:arc, :oidc, [])
    |> Keyword.get(:admin_emails, [])
    |> Enum.map(&String.downcase(String.trim(&1)))
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
