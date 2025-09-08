defmodule Aprstx.Repo do
  use Ecto.Repo,
    otp_app: :aprstx,
    adapter: Ecto.Adapters.SQLite3
end
