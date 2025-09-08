defmodule Aprstx.Configuration do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  schema "configurations" do
    field(:key, :string)
    field(:value, :map)
    field(:category, :string)

    timestamps()
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [:key, :value, :category])
    |> validate_required([:key, :value, :category])
    |> unique_constraint(:key)
  end
end
