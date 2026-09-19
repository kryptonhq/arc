defmodule ArcWeb.Admin.AuditHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  def index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:audit}>
      <.page_header title="Audit log" subtitle="Administrative actions, newest first." />
      <.card>
        <p :if={@entries == []} class="text-sm text-zinc-500">Nothing recorded yet.</p>
        <table :if={@entries != []} class="w-full text-left text-sm">
          <thead class="text-xs uppercase text-zinc-500">
            <tr>
              <th class="py-2">Time</th><th>Admin</th><th>Action</th><th>App</th><th>Details</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100">
            <tr :for={e <- @entries}>
              <td class="whitespace-nowrap py-2 text-zinc-500">{fmt_time(e.inserted_at)}</td>
              <td>{(e.admin_user && e.admin_user.email) || "system"}</td>
              <td><code class="text-xs">{e.action}</code></td>
              <td class="tabular-nums">{e.app_id}</td>
              <td class="max-w-md truncate font-mono text-xs text-zinc-500">
                {Jason.encode!(e.metadata)}
              </td>
            </tr>
          </tbody>
        </table>
        <div class="mt-4 flex gap-2">
          <.btn :if={@page > 1} href={~p"/admin/audit?page=#{@page - 1}"}>Newer</.btn>
          <.btn :if={@more?} href={~p"/admin/audit?page=#{@page + 1}"}>Older</.btn>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
