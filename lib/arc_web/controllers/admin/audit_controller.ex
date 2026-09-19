defmodule ArcWeb.Admin.AuditController do
  use ArcWeb, :controller

  @per_page 100

  plug :put_view, ArcWeb.Admin.AuditHTML

  def index(conn, params) do
    page =
      case Integer.parse(params["page"] || "1") do
        {page, ""} when page > 0 -> page
        _ -> 1
      end

    entries = Arc.Audit.list(limit: @per_page + 1, offset: (page - 1) * @per_page)

    render(conn, :index,
      entries: Enum.take(entries, @per_page),
      page: page,
      more?: length(entries) > @per_page,
      page_title: "Audit log"
    )
  end
end
