defmodule SqlclWrapper.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Plug.Cowboy.child_spec(scheme: :http, plug: SqlclWrapper.Router, options: [port: 4000])
    ]

    # Only start SqlclWrapper.SqlclProcess in non-test environments
    children = if Mix.env() != :test do
      [{SqlclWrapper.SqlclProcess, parent: self()}] ++ children
    else
      children
    end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SqlclWrapper.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
