defmodule AprstxWeb.CoreComponents do
  @moduledoc """
  Core UI components.
  """
  use Phoenix.Component

  @doc """
  Renders flash notices.
  """
  attr(:flash, :map, required: true)
  attr(:id, :string, default: "flash")

  def flash(%{flash: %{} = flash} = assigns) do
    ~H"""
    <div id={@id}>
      <%= if info = Phoenix.Flash.get(@flash, :info) do %>
        <div class="rounded-md bg-blue-50 p-4 mb-4">
          <div class="flex">
            <div class="ml-3">
              <p class="text-sm font-medium text-blue-800"><%= info %></p>
            </div>
          </div>
        </div>
      <% end %>
      
      <%= if error = Phoenix.Flash.get(@flash, :error) do %>
        <div class="rounded-md bg-red-50 p-4 mb-4">
          <div class="flex">
            <div class="ml-3">
              <p class="text-sm font-medium text-red-800"><%= error %></p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def flash(assigns), do: ~H""
end
