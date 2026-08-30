defmodule Convex.Protocol.Messages do
  @moduledoc false

  defmodule StateVersion do
    @moduledoc false
    @enforce_keys [:query_set, :identity, :ts]
    defstruct [:query_set, :identity, :ts]
  end

  defmodule Add do
    @moduledoc false
    @enforce_keys [:query_id, :udf_path, :args]
    defstruct [:query_id, :udf_path, :args, journal: :absent, component_path: :absent]
  end

  defmodule Remove do
    @moduledoc false
    @enforce_keys [:query_id]
    defstruct [:query_id]
  end

  defmodule Connect do
    @moduledoc false
    @enforce_keys [:session_id, :connection_count]
    defstruct [
      :session_id,
      :connection_count,
      :last_close_reason,
      :max_observed_timestamp,
      :client_ts
    ]
  end

  defmodule ModifyQuerySet do
    @moduledoc false
    @enforce_keys [:base_version, :new_version, :modifications]
    defstruct [:base_version, :new_version, :modifications]
  end

  defmodule Mutation do
    @moduledoc false
    @enforce_keys [:request_id, :udf_path, :args]
    defstruct [:request_id, :udf_path, :args, component_path: :absent]
  end

  defmodule Action do
    @moduledoc false
    @enforce_keys [:request_id, :udf_path, :args]
    defstruct [:request_id, :udf_path, :args, component_path: :absent]
  end

  defmodule Authenticate do
    @moduledoc false
    @enforce_keys [:base_version, :token]
    defstruct [:base_version, :token]
  end

  defmodule QueryUpdated do
    @moduledoc false
    @enforce_keys [:query_id, :value, :log_lines]
    defstruct [:query_id, :value, :log_lines, journal: :absent]
  end

  defmodule QueryFailed do
    @moduledoc false
    @enforce_keys [:query_id, :error_message, :log_lines]
    defstruct [:query_id, :error_message, :log_lines, journal: :absent, error_data: :absent]
  end

  defmodule QueryRemoved do
    @moduledoc false
    @enforce_keys [:query_id]
    defstruct [:query_id]
  end

  defmodule Transition do
    @moduledoc false
    @enforce_keys [:start_version, :end_version, :modifications]
    defstruct [:start_version, :end_version, :modifications, :client_clock_skew, :server_ts]
  end

  defmodule MutationResponse do
    @moduledoc false
    @enforce_keys [:request_id, :success, :result, :log_lines]
    defstruct [:request_id, :success, :result, :log_lines, :ts, error_data: :absent]
  end

  defmodule ActionResponse do
    @moduledoc false
    @enforce_keys [:request_id, :success, :result, :log_lines]
    defstruct [:request_id, :success, :result, :log_lines, error_data: :absent]
  end

  defmodule TransitionChunk do
    @moduledoc false
    @enforce_keys [:chunk, :part_number, :total_parts, :transition_id]
    defstruct [:chunk, :part_number, :total_parts, :transition_id]
  end

  defmodule AuthError do
    @moduledoc false
    @enforce_keys [:error]
    defstruct [:error, :base_version, :auth_update_attempted]
  end

  defmodule FatalError do
    @moduledoc false
    @enforce_keys [:error]
    defstruct [:error]
  end

  defmodule Ping do
    @moduledoc false
    defstruct []
  end
end
