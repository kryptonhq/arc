defmodule Arc.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:apps) do
      add :name, :text, null: false
      add :key, :text, null: false
      add :secret, :binary, null: false
      add :encryption_master_key, :binary
      add :enabled, :boolean, null: false, default: true
      add :client_events_enabled, :boolean, null: false, default: false
      add :enable_presence_limits, :boolean, null: false, default: true
      add :max_presence_members, :integer, null: false, default: 100
      add :max_connections, :integer
      add :max_payload_bytes, :integer, null: false, default: 10_240
      add :subscription_count_enabled, :boolean, null: false, default: false

      timestamps(type: :timestamptz)
    end

    create unique_index(:apps, [:key])

    create table(:webhook_endpoints) do
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :secret, :binary
      add :events, {:array, :text}, null: false, default: []
      add :active, :boolean, null: false, default: true

      timestamps(type: :timestamptz)
    end

    create index(:webhook_endpoints, [:app_id])

    create table(:webhook_deliveries) do
      add :endpoint_id, references(:webhook_endpoints, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :payload, :map, null: false
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :next_attempt_at, :timestamptz
      add :delivered_at, :timestamptz

      timestamps(type: :timestamptz, updated_at: false)
    end

    create index(:webhook_deliveries, [:status, :next_attempt_at])
    create index(:webhook_deliveries, [:endpoint_id, :inserted_at])
    create index(:webhook_deliveries, [:app_id, :inserted_at])

    create table(:admin_users) do
      add :email, :citext, null: false
      add :subject, :text
      add :last_login_at, :timestamptz

      timestamps(type: :timestamptz)
    end

    create unique_index(:admin_users, [:email])

    create table(:audit_log) do
      add :admin_user_id, references(:admin_users, on_delete: :nilify_all)
      add :action, :text, null: false
      add :app_id, :bigint
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :timestamptz, updated_at: false)
    end

    create index(:audit_log, [:inserted_at])
    create index(:audit_log, [:app_id])
  end
end
