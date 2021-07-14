defmodule ExMQTT do
  @moduledoc """
  Documentation for MQTT client.
  """

  use GenServer

  require Logger

  defmodule Message do
    @moduledoc """
    Defines an incomming message
    """

    @type t :: %__MODULE__{
            topic: String.t(),
            payload: String.t(),
            retain: boolean()
          }
    @enforce_keys [:topic, :payload, :retain]
    defstruct [:topic, :payload, :retain]
  end

  defmodule State do
    defstruct [
      :conn_pid,
      :username,
      :client_id,
      :handler,
      :opts,
      :protocol_version,
      :reconnect,
      :subscriptions
    ]
  end

  @type opts :: [
          {:name, atom}
          | {:owner, pid}
          | {:handler, module}
          | {:host, binary}
          | {:hosts, [{binary, :inet.port_number()}]}
          | {:port, :inet.port_number()}
          | {:tcp_opts, [:gen_tcp.option()]}
          | {:ssl, boolean}
          | {:ssl_opts, [keyword()]}
          | {:ws_path, binary}
          | {:connect_timeout, pos_integer}
          | {:bridge_mode, boolean}
          | {:client_id, iodata}
          | {:clean_start, boolean}
          | {:username, iodata}
          | {:password, iodata}
          | {:protocol_version, 3 | 4 | 5}
          | {:keepalive, non_neg_integer}
          | {:max_inflight, pos_integer}
          | {:retry_interval, timeout}
          | {:will_topic, iodata}
          | {:will_payload, iodata}
          | {:will_retain, boolean}
          | {:will_qos, pos_integer}
          | {:will_props, %{atom => term}}
          | {:auto_ack, boolean}
          | {:ack_timeout, pos_integer}
          | {:force_ping, boolean}
          | {:properties, %{atom => term}}
          | {:reconnect, {delay :: non_neg_integer, max_delay :: non_neg_integer}}
          | {:subscriptions, [{topic :: binary, qos :: non_neg_integer}]}
          | {:start_when, {mfa, retry_in :: non_neg_integer}}
        ]

  @opt_keys [
    :name,
    :owner,
    :handler,
    :host,
    :hosts,
    :port,
    :tcp_opts,
    :ssl,
    :ssl_opts,
    :ws_path,
    :connect_timeout,
    :bridge_mode,
    :client_id,
    :clean_start,
    :username,
    :password,
    :protocol_version,
    :keepalive,
    :max_inflight,
    :retry_interval,
    :will_topic,
    :will_payload,
    :will_retain,
    :will_qos,
    :will_props,
    :auto_ack,
    :ack_timeout,
    :force_ping,
    :opts,
    :properties,
    :reconnect,
    :subscriptions,
    :start_when
  ]

  @doc """
  Start the MQTT Client GenServer.
  """
  @spec start_link(opts) :: {:ok, pid}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Async

  @spec publish(message :: String.t(), topic :: String.t(), qos :: integer()) :: :ok
  def publish(message, topic, qos) do
    GenServer.cast(__MODULE__, {:publish, message, topic, qos})
  end

  @spec subscribe(topic :: String.t(), qos :: integer()) :: :ok
  def subscribe(topic, qos) do
    GenServer.cast(__MODULE__, {:subscribe, topic, qos})
  end

  @spec unsubscribe(topic :: String.t()) :: :ok
  def unsubscribe(topic) do
    GenServer.cast(__MODULE__, {:unsubscribe, topic})
  end

  @spec disconnect() :: :ok
  def disconnect do
    GenServer.cast(__MODULE__, :disconnect)
  end

  ## Sync

  @spec publish_sync(message :: String.t(), topic :: String.t(), qos :: integer()) :: :ok
  def publish_sync(message, topic, qos) do
    GenServer.call(__MODULE__, {:publish, message, topic, qos})
  end

  @spec subscribe_sync(topic :: String.t(), qos :: integer()) :: :ok
  def subscribe_sync(topic, qos) do
    GenServer.call(__MODULE__, {:subscribe, topic, qos})
  end

  @spec unsubscribe_sync(topic :: String.t()) :: :ok
  def unsubscribe_sync(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic})
  end

  @spec disconnect_sync() :: :ok
  def disconnect_sync do
    GenServer.call(__MODULE__, :disconnect)
  end

  # ----------------------------------------------------------------------------
  # Callbacks
  # ----------------------------------------------------------------------------

  ## Init

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    opts = take_opts(opts)
    {{delay, max_delay}, opts} = Keyword.pop(opts, :reconnect, {500, 60_000})
    {start_when, opts} = Keyword.pop(opts, :start_when, :now)
    {subscriptions, opts} = Keyword.pop(opts, :subscriptions, [])

    handler = opts[:handler]

    ssl_opts =
      opts
      |> Keyword.get(:ssl_opts, {})
      |> Keyword.put_new(:server_name_indication, String.to_charlist(opts[:host]))

    opts = Keyword.put(opts, :ssl_opts, ssl_opts)

    # EMQTT `msg_handler` functions
    handler_functions = %{
      puback: &handle_puback(&1, handler),
      publish: &handle_publish(&1, handler),
      disconnected: &handle_disconnect(&1, handler)
    }

    state = %State{
      client_id: opts[:client_id],
      protocol_version: opts[:protocol_version],
      reconnect: {delay, max_delay},
      subscriptions: subscriptions,
      username: opts[:username],
      handler: handler,
      opts: [{:msg_handler, handler_functions} | opts]
    }

    {:ok, state, {:continue, {:start_when, start_when}}}
  end

  ## Continue

  @impl GenServer

  def handle_continue({:start_when, :now}, state) do
    {:noreply, state, {:continue, {:connect, 0}}}
  end

  def handle_continue({:start_when, start_when}, state) do
    {{module, function, args}, retry_in} = start_when

    if apply(module, function, args) do
      {:noreply, state, {:continue, {:connect, 0}}}
    else
      Process.sleep(retry_in)
      {:noreply, state, {:continue, {:start_when, start_when}}}
    end
  end

  def handle_continue({:connect, attempt}, state) do
    case connect(state) do
      {:ok, state} ->
        :ok = sub(state, state.subscriptions)
        {:noreply, state}

      {:error, reason} ->
        %{reconnect: {initial_delay, max_delay}} = state
        delay = retry_delay(initial_delay, max_delay, attempt)
        Logger.debug("[ExMQTT] Unable to connect: #{inspect(reason)}, retrying in #{delay} ms")
        :timer.sleep(delay)
        {:noreply, state, {:continue, {:connect, attempt + 1}}}
    end
  end

  ## Call

  @impl GenServer

  def handle_call({:publish, message, topic, qos}, _from, state) do
    pub(state, message, topic, qos)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, topic, qos}, _from, state) do
    sub(state, topic, qos)
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, topic}, _from, state) do
    unsub(state, topic)
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    dc(state)
    {:reply, :ok, state}
  end

  ## Cast

  @impl GenServer

  def handle_cast({:publish, message, topic, qos}, state) do
    pub(state, message, topic, qos)
    {:noreply, state}
  end

  def handle_cast({:subscribe, topic, qos}, state) do
    sub(state, topic, qos)
    {:noreply, state}
  end

  def handle_cast({:unsubscribe, topic}, state) do
    unsub(state, topic)
    {:noreply, state}
  end

  def handle_cast(:disconnect, state) do
    dc(state)
    {:noreply, state}
  end

  ## Info

  @impl GenServer

  def handle_info({:publish, packet}, state) do
    %{payload: payload, topic: topic} = packet

    Logger.debug("[ExMQTT] Message received for #{topic}")

    if msg_handler = state.handlers[:message] do
      :ok = msg_handler.(String.split(topic, "/"), payload)
    end

    {:noreply, state}
  end

  def handle_info({:disconnected, :shutdown, :ssl_closed}, state) do
    Logger.warn("[ExMQTT] Disconnected - shutdown, :ssl_closed")
    {:noreply, state}
  end

  def handle_info({:reconnect, attempt}, %{reconnect: {initial_delay, max_delay}} = state) do
    Logger.debug("[ExMQTT] Trying to reconnect")

    case connect(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        delay = retry_delay(initial_delay, max_delay, attempt)
        Logger.debug("[ExMQTT] Unable to reconnect: #{inspect(reason)}, retrying in #{delay} ms")
        Process.send_after(self(), {:reconnect, attempt + 1}, delay)
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _}, state) do
    if pid == state.conn_pid do
      Logger.warn("[ExMQTT] Got Exit")
      Process.send_after(self(), {:reconnect, 0}, 0)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn("[ExMQTT] Unhandled message #{inspect(msg)}")
    {:noreply, state}
  end

  ## Disconnect

  def handle_disconnect({reason_code, properties}, handler) do
    Logger.warn(
      "[ExMQTT] Disconnect received: reason #{reason_code}, properties: #{inspect(properties)}"
    )

    if handler != nil do
      :ok = handler.handle_disconnect(reason_code, properties)
    end

    # Process.send_after(self(), {:reconnect, 0}, 500)

    :ok
  rescue
    e ->
      Logger.error("Got error in handle_disconnect: #{inspect(e)}")
      :ok
  end

  ## PubAck

  def handle_puback(ack, handler) do
    Logger.debug("[ExMQTT] PUBACK received #{inspect(ack)}")

    if handler != nil do
      :ok = handler.handle_puback(ack)
    end

    :ok
  rescue
    e ->
      Logger.error("Got error in handle_puback: #{inspect(e)}")
      :ok
  end

  ## Publish

  def handle_publish(message, handler) do
    Logger.debug("[ExMQTT] Publish: #{inspect(message)}")
    topic = String.split(message.topic, "/")

    message = struct(Message, message)

    if handler != nil do
      :ok = handler.handle_message(topic, message)
    end

    :ok
  rescue
    e ->
      Logger.error("Got error in handle_publish: #{inspect(e)}")
      :ok
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp connect(%State{} = state) do
    Logger.debug("[ExMQTT] Connecting to #{state.opts[:host]}:#{state.opts[:port]}")

    opts = map_opts(state.opts)

    with(
      {:ok, conn_pid} when is_pid(conn_pid) <- :emqtt.start_link(opts),
      {:ok, _props} <- :emqtt.connect(conn_pid)
    ) do
      Logger.debug("[ExMQTT] Connected #{inspect(conn_pid)}")

      if state.handler != nil do
        :ok = state.handler.handle_connect()
      end

      {:ok, %State{state | conn_pid: conn_pid}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pub(%State{} = state, message, topic, qos) do
    if qos == 0 do
      :ok = :emqtt.publish(state.conn_pid, topic, message, qos)
    else
      {:ok, _packet_id} = :emqtt.publish(state.conn_pid, topic, message, qos)
    end
  end

  defp sub(%State{} = state, topics) when is_list(topics) do
    Enum.each(topics, fn {topic, qos} ->
      :ok = sub(state, topic, qos)
    end)
  end

  defp sub(%State{} = state, topic, qos) do
    case :emqtt.subscribe(state.conn_pid, {topic, qos}) do
      {:ok, _props, [reason_code]} when reason_code in [0x00, 0x01, 0x02] ->
        Logger.debug("[ExMQTT] Subscribed to #{topic} @ QoS #{qos}")
        :ok

      {:ok, _props, reason_codes} ->
        Logger.error(
          "[ExMQTT] Subscription to #{topic} @ QoS #{qos} failed: #{inspect(reason_codes)}"
        )

        :error
    end
  end

  defp unsub(%State{} = state, topic) do
    case :emqtt.unsubscribe(state.conn_pid, topic) do
      {:ok, _props, [0x00]} ->
        Logger.debug("[ExMQTT] Unsubscribed from #{topic}")
        :ok

      {:ok, _props, reason_codes} ->
        Logger.error("[ExMQTT] Unsubscribe from #{topic} failed #{inspect(reason_codes)}")
        :error
    end
  end

  defp dc(%State{} = state) do
    :ok = :emqtt.disconnect(state.conn_pid)
  end

  ## Utility

  defp take_opts(opts) do
    case Keyword.split(opts, @opt_keys) do
      {keep, []} -> keep
      {_keep, extra} -> raise ArgumentError, "Unrecognized options #{inspect(extra)}"
    end
  end

  # Backoff with full jitter (after 3 attempts).
  defp retry_delay(initial_delay, _max_delay, attempt) when attempt < 3 do
    initial_delay
  end

  defp retry_delay(initial_delay, max_delay, attempt) when attempt < 1000 do
    temp = min(max_delay, pow(initial_delay * 2, attempt))
    trunc(temp / 2 + Enum.random([0, temp / 2]))
  end

  defp retry_delay(_initial_delay, max_delay, _attempt) do
    max_delay
  end

  # Integer powers:
  # https://stackoverflow.com/a/44065965/2066155
  defp pow(n, k), do: pow(n, k, 1)
  defp pow(_, 0, acc), do: acc
  defp pow(n, k, acc), do: pow(n, k - 1, n * acc)

  # emqtt has some odd opt names and some erlang types that we'll want to
  # redefine but then map to emqtt expected format.
  defp map_opts(opts) do
    Enum.reduce(opts, [], &map_opt/2)
  end

  defp map_opt({:clean_session, val}, opts) do
    [{:clean_start, val} | opts]
  end

  defp map_opt({:client_id, val}, opts) do
    [{:clientid, val} | opts]
  end

  defp map_opt({:handler_functions, val}, opts) do
    [{:msg_handler, val} | opts]
  end

  defp map_opt({:host, val}, opts) do
    [{:host, to_charlist(val)} | opts]
  end

  defp map_opt({:hosts, hosts}, opts) do
    hosts = Enum.map(hosts, fn {host, port} -> {to_charlist(host), port} end)
    [{:hosts, hosts} | opts]
  end

  defp map_opt({:protocol_version, val}, opts) do
    version =
      case val do
        3 -> :v3
        4 -> :v4
        5 -> :v5
      end

    [{:proto_ver, version} | opts]
  end

  defp map_opt({:ws_path, val}, opts) do
    [{:ws_path, to_charlist(val)} | opts]
  end

  defp map_opt(opt, opts) do
    [opt | opts]
  end
end
