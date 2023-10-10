defmodule Xandra.Connection do
  @moduledoc false

  import Record
  import Xandra.Transport, only: [is_data_message: 2, is_closed_message: 2, is_error_message: 2]

  alias Xandra.Backoff
  alias Xandra.Batch
  alias Xandra.ConnectionError
  alias Xandra.Connection.Utils
  alias Xandra.Frame
  alias Xandra.GenStatemHelpers
  alias Xandra.Prepared
  alias Xandra.SetKeyspace
  alias Xandra.Simple
  alias Xandra.Transport

  @behaviour :gen_statem

  @forced_transport_options [packet: :raw, mode: :binary, active: false]
  @max_concurrent_requests 5000

  # This record is used internally when we check out a "view" of the state of
  # the connection. This holds all the necessary info to encode queries and more.
  # It's a record just so that we don't have to create yet another module for a struct.
  defrecordp :checked_out_state, [
    :address,
    :atom_keys?,
    :compressor,
    :connection_name,
    :current_keyspace,
    :default_consistency,
    :port,
    :prepared_cache,
    :protocol_module,
    :stream_id,
    :transport
  ]

  ## Public API

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) when is_list(opts) do
    {gen_statem_opts, opts} = GenStatemHelpers.split_opts(opts)
    GenStatemHelpers.start_link_with_name_registration(__MODULE__, opts, gen_statem_opts)
  end

  @spec prepare(:gen_statem.server_ref(), Prepared.t(), keyword()) ::
          {:ok, Prepared.t()} | {:error, Xandra.error()}
  def prepare(conn, %Prepared{} = prepared, options) when is_list(options) do
    conn_pid = GenServer.whereis(conn)
    req_alias = Process.monitor(conn_pid, alias: :reply_demonitor)

    telemetry_metadata = Keyword.fetch!(options, :telemetry_metadata)

    case :gen_statem.call(conn_pid, {:checkout_state_for_next_request, req_alias}) do
      {:ok, checked_out_state() = state} ->
        checked_out_state(
          protocol_module: protocol_module,
          stream_id: stream_id,
          prepared_cache: prepared_cache
        ) = state

        metadata =
          telemetry_meta(state, conn_pid, %{
            query: prepared,
            extra_metadata: telemetry_metadata
          })

        options = Keyword.put(options, :stream_id, stream_id)
        prepared = hydrate_query(prepared, state, options)
        timeout = Keyword.fetch!(options, :timeout)

        case prepared_cache_lookup(prepared_cache, prepared, Keyword.fetch!(options, :force)) do
          # If the prepared query was in the cache, we emit a Telemetry event and we must
          # make sure to put the stream ID we checked out back into the pool.
          {:ok, prepared} ->
            :telemetry.execute([:xandra, :prepared_cache, :hit], %{}, metadata)
            :gen_statem.cast(conn_pid, {:release_stream_id, stream_id})
            {:ok, prepared}

          {:error, cache_status} ->
            # If the prepared query is not in the cache, we need to prepare it and then
            # cache it.
            :telemetry.execute([:xandra, :prepared_cache, cache_status], %{}, metadata)

            :telemetry.span([:xandra, :prepare_query], metadata, fn ->
              with :ok <- send_prepare_frame(state, prepared, options),
                   {:ok, %Frame{} = frame} <- receive_response_frame(req_alias, state, timeout) do
                case protocol_module.decode_response(frame, prepared, options) do
                  {%Prepared{} = prepared, warnings} ->
                    Prepared.Cache.insert(prepared_cache, prepared)

                    maybe_execute_telemetry_for_warnings(
                      state,
                      conn_pid,
                      prepared,
                      warnings
                    )

                    reprepared = cache_status == :hit
                    {{:ok, prepared}, Map.put(metadata, :reprepared, reprepared)}

                  %Xandra.Error{} = error ->
                    {{:error, error}, Map.put(metadata, :reason, error)}
                end
              else
                {:error, reason} ->
                  reason = ConnectionError.new("prepare", reason)
                  {{:error, reason}, Map.put(metadata, :reason, reason)}
              end
            end)
        end
    end
  end

  defp send_prepare_frame(
         checked_out_state(protocol_module: protocol_module, transport: transport),
         %Prepared{compressor: compressor} = prepared,
         options
       ) do
    frame_options =
      options
      |> Keyword.take([:tracing, :custom_payload, :stream_id])
      |> Keyword.put(:compressor, compressor)

    payload =
      Frame.new(:prepare, frame_options)
      |> protocol_module.encode_request(prepared)
      |> Frame.encode(protocol_module)

    case Transport.send(transport, payload) do
      :ok -> :ok
      {:error, reason} -> {:error, ConnectionError.new("prepare", reason)}
    end
  end

  @spec execute(:gen_statem.server_ref(), Batch.t(), nil, keyword()) ::
          {:ok, Xandra.result()} | {:error, Xandra.error()}
  @spec execute(:gen_statem.server_ref(), Simple.t() | Prepared.t(), Xandra.values(), keyword()) ::
          {:ok, Xandra.result()} | {:error, Xandra.error()}
  def execute(conn, %query_mod{} = query, params, options) when is_list(options) do
    conn_pid = GenServer.whereis(conn)
    req_alias = Process.monitor(conn_pid, alias: :reply_demonitor)

    case :gen_statem.call(conn_pid, {:checkout_state_for_next_request, req_alias}) do
      {:ok, checked_out_state() = checked_out_state} ->
        checked_out_state(
          transport: %Transport{} = transport,
          protocol_module: protocol_module,
          stream_id: stream_id
        ) = checked_out_state

        options = Keyword.put(options, :stream_id, stream_id)
        query = hydrate_query(query, checked_out_state, options)
        timeout = Keyword.fetch!(options, :timeout)
        payload = query_mod.encode(query, params, options)

        # This is in an anonymous function so that we can use it in a Telemetry span.
        fun = fn ->
          with :ok <- Transport.send(transport, payload),
               {:ok, %Frame{} = frame} <-
                 receive_response_frame(req_alias, checked_out_state, timeout) do
            case protocol_module.decode_response(frame, query, options) do
              {%_{} = response, warnings} ->
                maybe_execute_telemetry_for_warnings(checked_out_state, conn_pid, query, warnings)

                # If the query was a "USE keyspace" query, we need to update the current
                # keyspace for the connection. This is race conditioney, but it's probably ok.
                case response do
                  %SetKeyspace{keyspace: keyspace} ->
                    :gen_statem.cast(conn_pid, {:set_keyspace, keyspace})

                  _other ->
                    :ok
                end

                {:ok, response}

              %Xandra.Error{} = error ->
                {:error, error}
            end
          else
            {:error, reason} ->
              {:error, ConnectionError.new("execute", reason)}
          end
        end

        telemetry_meta =
          checked_out_state
          |> telemetry_meta(conn_pid, %{query: query})
          |> Map.put(:extra_metadata, options[:telemetry_metadata])

        :telemetry.span([:xandra, :execute_query], telemetry_meta, fn ->
          {fun.(), telemetry_meta}
        end)

      {:error, %ConnectionError{} = error} ->
        {:error, error}
    end
  end

  defp hydrate_query(%Simple{} = simple, checked_out_state() = response, options) do
    %Simple{
      simple
      | default_consistency: checked_out_state(response, :default_consistency),
        protocol_module: checked_out_state(response, :protocol_module),
        compressor: get_right_compressor(response, options[:compressor]),
        custom_payload: options[:custom_payload]
    }
  end

  defp hydrate_query(%Batch{} = batch, checked_out_state() = response, options) do
    %Batch{
      batch
      | default_consistency: checked_out_state(response, :default_consistency),
        protocol_module: checked_out_state(response, :protocol_module),
        compressor: get_right_compressor(response, options[:compressor]),
        custom_payload: options[:custom_payload]
    }
  end

  defp hydrate_query(%Prepared{} = prepared, checked_out_state() = response, options) do
    %Prepared{
      prepared
      | default_consistency: checked_out_state(response, :default_consistency),
        protocol_module: checked_out_state(response, :protocol_module),
        keyspace: checked_out_state(response, :current_keyspace),
        compressor: get_right_compressor(response, options[:compressor]),
        request_custom_payload: options[:custom_payload]
    }
  end

  defp receive_response_frame(req_alias, checked_out_state(atom_keys?: atom_keys?), timeout) do
    receive do
      {^req_alias, {:ok, %Frame{} = frame}} ->
        frame = %Frame{frame | atom_keys?: atom_keys?}
        {:ok, frame}

      {^req_alias, {:error, %ConnectionError{} = error}} ->
        {:error, error}

      {:DOWN, ^req_alias, _, _, reason} ->
        {:error, {:connection_crashed, reason}}
    after
      timeout ->
        Process.demonitor(req_alias, [:flush])
        {:error, :timeout}
    end
  end

  # Made public for testing. Only meant to be used in tests.
  def get_transport(conn) do
    :gen_statem.call(conn, :get_transport)
  end

  ## Data

  # [short] - a 2-byte integer, which clients can only use as a *positive* integer (so
  # half of the range)
  @type stream_id() :: 1..32_768

  # This type is just for documentation.
  @type t() :: %__MODULE__{
          address: String.t(),
          atom_keys?: boolean(),
          backoff: Backoff.t(),
          buffer: binary(),
          cluster_pid: pid() | nil,
          compressor: module() | nil,
          configure: {module(), atom(), [term()]} | (keyword() -> keyword()) | nil,
          connect_timeout: timeout(),
          connection_name: term(),
          current_keyspace: String.t() | nil,
          default_consistency: atom(),
          disconnection_reason: term(),
          free_stream_ids: MapSet.t(stream_id()),
          in_flight_requests: %{optional(stream_id()) => term()},
          options: keyword(),
          original_options: keyword(),
          peername: {:inet.ip_address(), :inet.port_number()},
          port: term(),
          prepared_cache: term(),
          protocol_module: module(),
          protocol_version: nil | Frame.supported_protocol(),
          transport: Transport.t()
        }

  defstruct [
    :address,
    :atom_keys?,
    :backoff,
    :cluster_pid,
    :compressor,
    :configure,
    :connect_timeout,
    :connection_name,
    :default_consistency,
    :disconnection_reason,
    :options,
    :original_options,
    :peername,
    :port,
    :prepared_cache,
    :protocol_module,
    :protocol_version,
    :transport,
    free_stream_ids: MapSet.new(1..@max_concurrent_requests),
    in_flight_requests: %{},
    current_keyspace: nil,
    buffer: <<>>
  ]

  ## Callbacks

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(options) do
    data = %__MODULE__{original_options: options, configure: Keyword.get(options, :configure)}
    {:ok, :disconnected, data, {:next_event, :internal, :connect}}
  end

  ## "Disconnected" state

  def disconnected(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  def disconnected(:enter, :connected, %__MODULE__{} = data) do
    {reason, data} = get_and_update_in(data.disconnection_reason, &{&1, nil})
    :telemetry.execute([:xandra, :disconnected], %{}, telemetry_meta(data, %{reason: reason}))

    if data.cluster_pid do
      send(data.cluster_pid, {:xandra, :disconnected, data.peername, self()})
    end

    data =
      Enum.reduce(data.in_flight_requests, data, fn {stream_id, req_alias}, data_acc ->
        send_reply(req_alias, {:error, ConnectionError.new("request", :disconnected)})
        update_in(data_acc.free_stream_ids, &MapSet.put(&1, stream_id))
      end)

    data = put_in(data.in_flight_requests, %{})

    if data.backoff do
      {backoff_time, data} = get_and_update_in(data.backoff, &Backoff.backoff/1)
      {:keep_state, data, {{:timeout, :reconnect}, backoff_time, _content = nil}}
    else
      {:stop, reason}
    end
  end

  def disconnected(:internal, :connect, %__MODULE__{} = data) do
    # First, potentially reconfigure the options.
    options =
      case data.configure do
        {mod, fun, args} -> apply(mod, fun, [data.original_options | args])
        fun when is_function(fun, 1) -> fun.(data.original_options)
        nil -> data.original_options
      end

    # Now, build the state from the options.
    {address, port} = Keyword.fetch!(options, :node)

    transport = %Transport{
      module: if(options[:encryption], do: :ssl, else: :gen_tcp),
      options:
        options
        |> Keyword.get(:transport_options, [])
        |> Keyword.merge(@forced_transport_options)
    }

    data = %__MODULE__{
      data
      | transport: transport,
        prepared_cache: Keyword.fetch!(options, :prepared_cache),
        compressor: Keyword.get(options, :compressor),
        default_consistency: Keyword.fetch!(options, :default_consistency),
        atom_keys?: Keyword.fetch!(options, :atom_keys),
        address: address,
        port: port,
        connect_timeout: Keyword.fetch!(options, :connect_timeout),
        connection_name: Keyword.get(options, :name),
        cluster_pid: Keyword.get(options, :cluster_pid),
        protocol_version: Keyword.get(options, :protocol_version),
        options: options,
        backoff:
          data.backoff ||
            Backoff.new(Keyword.take(options, [:backoff_type, :backoff_min, :backoff_max]))
    }

    case Transport.connect(transport, String.to_charlist(address), port, data.connect_timeout) do
      {:ok, transport} ->
        {:ok, peername} = Transport.address_and_port(transport)
        data = %__MODULE__{data | transport: transport, peername: peername}

        with {:ok, supported_options, protocol_module} <-
               Utils.request_options(data.transport, data.protocol_version),
             data = %__MODULE__{data | protocol_module: protocol_module},
             :ok <-
               startup_connection(
                 data.transport,
                 supported_options,
                 protocol_module,
                 data.compressor,
                 data.options
               ) do
          :telemetry.execute(
            [:xandra, :connected],
            %{},
            telemetry_meta(data, %{
              protocol_module: protocol_module,
              supported_options: supported_options
            })
          )

          if data.cluster_pid do
            send(data.cluster_pid, {:xandra, :connected, data.peername, self()})
          end

          {:next_state, :connected, data}
        else
          {:error, {:unsupported_protocol, protocol_version}} ->
            raise """
            native protocol version negotiation with the server failed. The server \
            wants to use protocol #{inspect(protocol_version)}, but Xandra only \
            supports these protocols: #{inspect(Frame.supported_protocols())}\
            """

          {:error, {:use_this_protocol_instead, failed_protocol_version, protocol_version}} ->
            :telemetry.execute(
              [:xandra, :debug, :downgrading_protocol],
              %{},
              telemetry_meta(data, %{
                failed_version: failed_protocol_version,
                new_version: protocol_version
              })
            )

            data = %__MODULE__{
              data
              | transport: Transport.close(transport),
                protocol_version: protocol_version
            }

            {:keep_state, data, {:next_event, :internal, :connect}}

          {:error, %Xandra.Error{} = error} ->
            raise error

          {:error, reason} ->
            {:keep_state, data, {:next_event, :internal, {:failed_to_connect, reason}}}
        end

      {:error, reason} ->
        {:keep_state, data, {:next_event, :internal, {:failed_to_connect, reason}}}
    end
  end

  def disconnected(:internal, {:failed_to_connect, reason}, %__MODULE__{} = data) do
    ipfied_address =
      case data.address |> String.to_charlist() |> :inet.parse_address() do
        {:ok, ip} -> ip
        {:error, _reason} -> data.address
      end

    :telemetry.execute(
      [:xandra, :failed_to_connect],
      %{},
      telemetry_meta(data, %{reason: reason})
    )

    if data.cluster_pid do
      send(
        data.cluster_pid,
        {:xandra, :failed_to_connect, {ipfied_address, data.port}, self()}
      )
    end

    if data.backoff do
      {backoff_time, data} = get_and_update_in(data.backoff, &Backoff.backoff/1)
      {:keep_state, data, {{:timeout, :reconnect}, backoff_time, _content = nil}}
    else
      {:stop, reason}
    end
  end

  def disconnected({:timeout, :reconnect}, nil, %__MODULE__{} = _data) do
    {:keep_state_and_data, {:next_event, :internal, :connect}}
  end

  def disconnected({:call, from}, {:checkout_state_for_next_request, _req_alias}, _data) do
    reply = {:error, ConnectionError.new("request", :not_connected)}
    {:keep_state_and_data, {:reply, from, reply}}
  end

  def disconnected({:call, from}, :get_transport, %__MODULE__{}) do
    {:keep_state_and_data, {:reply, from, {:error, :disconnected}}}
  end

  def disconnected(:cast, {:set_keyspace, _keyspace}, _data) do
    :keep_state_and_data
  end

  def disconnected(:cast, {:release_stream_id, stream_id}, %__MODULE__{} = data) do
    data = update_in(data.free_stream_ids, &MapSet.put(&1, stream_id))
    data = update_in(data.in_flight_requests, &Map.delete(&1, stream_id))
    {:keep_state, data}
  end

  ## "Connected" state

  def connected(:enter, :disconnected, %__MODULE__{} = data) do
    if keyspace = data.options[:keyspace] do
      query = %Simple{
        statement: "USE #{keyspace}",
        default_consistency: data.default_consistency,
        protocol_module: data.protocol_module,
        custom_payload: data.options[:custom_payload]
      }

      payload = Simple.encode(query, _params = [], stream_id: 0)
      protocol_format = Xandra.Protocol.frame_protocol_format(data.protocol_module)

      with :ok <- Transport.send(data.transport, payload),
           {:ok, frame, _rest} <-
             Utils.recv_frame(data.transport, protocol_format, data.compressor),
           # TODO: warnings?
           {%SetKeyspace{}, _warnings} = data.protocol_module.decode_response(frame, query),
           :ok <- Transport.setopts(data.transport, active: :once) do
        {:keep_state, %__MODULE__{data | current_keyspace: keyspace}}
      else
        {:error, reason} -> disconnect(data, reason)
      end
    else
      case Transport.setopts(data.transport, active: :once) do
        :ok -> {:keep_state_and_data, {{:timeout, :reconnect}, :infinity, nil}}
        {:error, reason} -> disconnect(data, reason)
      end
    end
  end

  def connected({:call, from}, {:checkout_state_for_next_request, req_alias}, data) do
    {stream_id, data} =
      get_and_update_in(data.free_stream_ids, fn ids ->
        id = Enum.at(ids, 0)
        {id, MapSet.delete(ids, id)}
      end)

    response =
      checked_out_state(
        address: data.address,
        atom_keys?: data.atom_keys?,
        compressor: data.compressor,
        connection_name: data.connection_name,
        current_keyspace: data.current_keyspace,
        default_consistency: data.default_consistency,
        port: data.port,
        prepared_cache: data.prepared_cache,
        protocol_module: data.protocol_module,
        stream_id: stream_id,
        transport: data.transport
      )

    data = put_in(data.in_flight_requests[stream_id], req_alias)

    {:keep_state, data, {:reply, from, {:ok, response}}}
  end

  def connected({:call, from}, :get_transport, %__MODULE__{transport: transport}) do
    {:keep_state_and_data, {:reply, from, {:ok, transport}}}
  end

  def connected(:info, message, data) when is_data_message(data.transport, message) do
    :ok = Transport.setopts(data.transport, active: :once)
    {_mod, _socket, bytes} = message
    data = update_in(data.buffer, &(&1 <> bytes))
    handle_new_bytes(data)
  end

  def connected(:info, message, data) when is_closed_message(data.transport, message) do
    disconnect(data, :closed)
  end

  def connected(:info, message, data) when is_error_message(data.transport, message) do
    {_mod, _socket, reason} = message
    disconnect(data, reason)
  end

  def connected(:cast, {:set_keyspace, keyspace}, %__MODULE__{} = data) do
    {:keep_state, %__MODULE__{data | current_keyspace: keyspace}}
  end

  def connected(:cast, {:release_stream_id, stream_id}, %__MODULE__{} = data) do
    data = update_in(data.free_stream_ids, &MapSet.put(&1, stream_id))
    data = update_in(data.in_flight_requests, &Map.delete(&1, stream_id))
    {:keep_state, data}
  end

  ## Helpers

  defp startup_connection(
         %Transport{} = transport,
         supported_options,
         protocol_module,
         compressor,
         options
       ) do
    %{
      "CQL_VERSION" => [cql_version | _],
      "COMPRESSION" => supported_compression_algorithms
    } = supported_options

    requested_options = %{"CQL_VERSION" => cql_version}

    if compressor do
      compression_algorithm = Atom.to_string(compressor.algorithm())

      if compression_algorithm in supported_compression_algorithms do
        requested_options = Map.put(requested_options, "COMPRESSION", compression_algorithm)

        Utils.startup_connection(
          transport,
          requested_options,
          protocol_module,
          compressor,
          options
        )
      else
        {:error,
         ConnectionError.new(
           "startup connection",
           {:unsupported_compression, compressor.algorithm()}
         )}
      end
    else
      Utils.startup_connection(
        transport,
        requested_options,
        protocol_module,
        compressor,
        options
      )
    end
  end

  defp disconnect(%__MODULE__{} = data, reason) do
    data = %__MODULE__{data | disconnection_reason: reason}
    {:next_state, :disconnected, data}
  end

  defp handle_new_bytes(%__MODULE__{} = data) do
    fetch_bytes_fun = fn buffer, byte_count ->
      case buffer do
        <<frame_bytes::binary-size(byte_count), rest::binary>> -> {:ok, frame_bytes, rest}
        _other -> {:error, :insufficient_data}
      end
    end

    case Frame.decode(
           data.protocol_module,
           fetch_bytes_fun,
           data.buffer,
           data.compressor,
           _rest_fun = & &1
         ) do
      {:ok, frame, rest} ->
        %__MODULE__{data | buffer: rest}
        |> handle_frame(frame)
        |> handle_new_bytes()

      {:error, :insufficient_data} ->
        {:keep_state, data}

      {:error, reason} ->
        raise "malformed protocol frame: #{inspect(reason)}"
    end
  end

  defp handle_frame(%__MODULE__{} = data, %Frame{stream_id: stream_id} = frame) do
    case pop_in(data.in_flight_requests[stream_id]) do
      {nil, _data} ->
        raise """
        internal error in Xandra connection, we received a frame from the server with \
        stream ID #{stream_id}, but there was no in-flight request for this stream ID. \
        The frame is:

          #{inspect(frame)}
        """

      {req_alias, data} ->
        send_reply(req_alias, {:ok, frame})
        update_in(data.free_stream_ids, &MapSet.put(&1, stream_id))
    end
  end

  defp send_reply(req_alias, reply) do
    send(req_alias, {req_alias, reply})
  end

  defp telemetry_meta(%__MODULE__{} = data, extra_meta) do
    Map.merge(
      %{
        connection: self(),
        connection_name: data.connection_name,
        address: data.address,
        port: data.port
      },
      extra_meta
    )
  end

  defp telemetry_meta(checked_out_state() = resp, conn_pid, extra_meta) do
    meta =
      Map.merge(
        %{
          connection: conn_pid,
          connection_name: checked_out_state(resp, :connection_name),
          address: checked_out_state(resp, :address),
          port: checked_out_state(resp, :port)
        },
        extra_meta
      )

    if keyspace = checked_out_state(resp, :current_keyspace) do
      Map.put(meta, :current_keyspace, keyspace)
    else
      meta
    end
  end

  defp get_right_compressor(
         checked_out_state(compressor: conn_compressor, protocol_module: protocol_module),
         query_compressor
       ) do
    case Xandra.Protocol.frame_protocol_format(protocol_module) do
      :v5_or_more -> assert_valid_compressor(conn_compressor, query_compressor) || conn_compressor
      :v4_or_less -> assert_valid_compressor(conn_compressor, query_compressor)
    end
  end

  # If the user doesn't provide a compression module, it's fine because we don't
  # compress the outgoing frame (but we decompress the incoming frame).
  defp assert_valid_compressor(_initial, _provided = nil) do
    nil
  end

  # If this connection wasn't started with compression set up but the user
  # provides a compressor module, we blow up because it is a semantic error.
  defp assert_valid_compressor(_initial = nil, provided) do
    raise ArgumentError,
          "a query was compressed with the #{inspect(provided)} compressor module " <>
            "but the connection was started without specifying any compression"
  end

  # If the user provided a compressor module both for this prepare/execute as
  # well as when starting the connection, then we check that the compression
  # algorithm of both is the same (potentially, they can use different
  # compressor modules provided they use the same algorithm), and if not then
  # this is a semantic error so we blow up.
  defp assert_valid_compressor(initial, provided) do
    initial_algorithm = initial.algorithm()
    provided_algorithm = provided.algorithm()

    if initial_algorithm == provided_algorithm do
      provided
    else
      raise ArgumentError,
            "a query was compressed with the #{inspect(provided)} compressor module " <>
              "(which uses the #{inspect(provided_algorithm)} algorithm) but the " <>
              "connection was initialized with the #{inspect(initial)} compressor " <>
              "module (which uses the #{inspect(initial_algorithm)} algorithm)"
    end
  end

  defp prepared_cache_lookup(prepared_cache, prepared, true = _force?) do
    cache_status =
      case Prepared.Cache.lookup(prepared_cache, prepared) do
        {:ok, %Prepared{}} -> :hit
        :error -> :miss
      end

    Prepared.Cache.delete(prepared_cache, prepared)
    {:error, cache_status}
  end

  defp prepared_cache_lookup(prepared_cache, prepared, false = _force?) do
    case Prepared.Cache.lookup(prepared_cache, prepared) do
      {:ok, prepared} -> {:ok, prepared}
      :error -> {:error, :miss}
    end
  end

  defp maybe_execute_telemetry_for_warnings(
         checked_out_state() = resp,
         conn_pid,
         query,
         warnings
       ) do
    if warnings != [] do
      metadata = telemetry_meta(resp, conn_pid, %{query: query})
      :telemetry.execute([:xandra, :server_warnings], %{warnings: warnings}, metadata)
    end
  end
end
