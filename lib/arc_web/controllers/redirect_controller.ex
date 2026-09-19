defmodule ArcWeb.RedirectController do
  use ArcWeb, :controller

  def admin(conn, _params), do: redirect(conn, to: ~p"/admin")
end
