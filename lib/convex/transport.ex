defmodule Convex.Transport do
  @moduledoc false

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_text(pid(), binary()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
end
