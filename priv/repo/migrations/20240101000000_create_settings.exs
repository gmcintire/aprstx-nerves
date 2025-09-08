defmodule Aprstx.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :map
      add :category, :string
      add :description, :text
      
      timestamps()
    end

    create unique_index(:settings, [:key])
    create index(:settings, [:category])
  end
end