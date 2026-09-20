defmodule ArcWeb.Admin.AuditHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  def index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:audit}>
      <.page_header
        title="Audit log"
        subtitle="Who changed what, newest first. Written for app and webhook changes and every secret rotation."
      />

      <.page_body>
        <.panel body_class="px-5 py-1">
          <.empty
            :if={@entries == []}
            title="Nothing recorded yet"
            body="Creating an app, rotating a secret, or changing a webhook writes a line here."
          />

          <.table :if={@entries != []}>
            <:head>
              <th class="py-2.5 font-medium">When</th>
              <th class="font-medium">Admin</th>
              <th class="font-medium">Action</th>
              <th class="font-medium">App</th>
              <th class="font-medium">Details</th>
            </:head>
            <tr :for={entry <- @entries}>
              <td class="whitespace-nowrap py-2.5 text-ink-500" title={fmt_time(entry.inserted_at)}>
                {fmt_ago(entry.inserted_at)}
              </td>
              <td class="text-ink-800">
                {(entry.admin_user && entry.admin_user.email) || "system"}
              </td>
              <td>
                <span class={[
                  "font-mono text-xs",
                  destructive?(entry.action) && "text-rose-700",
                  !destructive?(entry.action) && "text-ink-800"
                ]}>
                  {entry.action}
                </span>
              </td>
              <td class="tabular text-ink-500">{entry.app_id}</td>
              <td class="max-w-xs truncate font-mono text-xs text-ink-400">
                {details(entry.metadata)}
              </td>
            </tr>
          </.table>
        </.panel>

        <div :if={@page > 1 or @more?} class="mt-4 flex gap-2">
          <.btn :if={@page > 1} href={~p"/admin/audit?page=#{@page - 1}"}>Newer</.btn>
          <.btn :if={@more?} href={~p"/admin/audit?page=#{@page + 1}"}>Older</.btn>
        </div>
      </.page_body>
    </Layouts.app>
    """
  end

  defp destructive?(action), do: action in ~w(app.deleted app.secret_rotated webhook.deleted)

  defp details(metadata) when metadata == %{}, do: ""
  defp details(metadata), do: Enum.map_join(metadata, "  ", fn {k, v} -> "#{k}=#{value(v)}" end)

  defp value(v) when is_list(v), do: Enum.join(v, ",")
  defp value(v), do: to_string(v)
end
