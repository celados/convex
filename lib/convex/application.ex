defmodule Convex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Convex.AuthTaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Convex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
