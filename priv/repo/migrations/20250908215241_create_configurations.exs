defmodule Aprstx.Repo.Migrations.CreateConfigurations do
  use Ecto.Migration

  def change do
    create table(:configurations) do
      add :key, :string, null: false
      add :value, :map, null: false
      add :category, :string, null: false
      
      timestamps()
    end

    create unique_index(:configurations, [:key])
    create index(:configurations, [:category])
  end
end