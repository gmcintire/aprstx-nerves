defmodule Aprstx.Config.Setting do
  @moduledoc """
  Schema for persistent configuration settings.
  Settings are stored in SQLite database in /data partition which persists across firmware updates.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "settings" do
    field(:key, :string)
    field(:value, :map)
    field(:category, :string)
    field(:description, :string)

    timestamps()
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :category, :description])
    |> validate_required([:key, :value, :category])
    |> unique_constraint(:key)
  end
end
