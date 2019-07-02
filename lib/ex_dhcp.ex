defmodule ExDhcp do
  @moduledoc """
  Creates an OTP-compliant DHCP server.

  An ExDhcp module binds to a UDP port, listens to DHCP messages sent
  to the port, and can resend DHCP messages
  (typically as a broadcast message) in response.

  You may instrument whatever state you would like into the server; the
  DHCP-specific contents will be encapsulated into the internals of the
  server itself and all of the state exposed to the callbacks will be
  your own state.

  **ExDhcp is not a fully-functional DHCP server** which conforms
  to the _RFC 1531_ specs.

  It does *not*:

  - keep the state of the DHCP leases
  - store DHCP lease information to durable storage
  - manage arp tables

  However, you *could* use ExDhcp to implement that functionality.
  For example, minimal ExDhcp server might look something like this:

  ```elixir
  defmodule MyDhcpServer do
    use ExDhcp
    alias ExDhcp.Packet

    def start_link(init_state) do
      ExDhcp.start_link(__MODULE__, init_state)
    end

    @impl true
    def init(init_state), do: {:ok, init_state}

    @impl true
    def handle_discover(request, xid, mac, state) do
      # code.  Should assign the unimplemented values
      # for the response below:
      response = Packet.respond(request, :offer,
        yiaddr: issued_your_address,
        siaddr: server_ip_address,
        subnet_mask: subnet_mask,
        routers: [router],
        lease_time: lease_time,
        server: server_ip_address,
        domain_name_servers: [dns_server]))

      {:respond, response, new_state}
    end

    @impl true
    def handle_request(request, xid, mac, state) do
      # code
      response = Packet.respond(request, :ack,
        yiaddr: issued_your_address ...)

      {:respond, response, state}
    end

    @impl true
    def handle_decline(request, xid, mac, state) do
      # code
      response = Packet.respond(request, :offer,
        yiaddr: new_issued_address ...)

      {:respond, response, state}
    end

  end
  ```

  You must implement the following three DHCP functionalities as callbacks to successfully
  assign network hosts:
  - `handle_discover/4`
  - `handle_request/4`
  - `handle_decline/4`

  You may also want to implement these callbacks:
  - `handle_inform/4` to manage a DHCP client requesting early info
  - `handle_release/4` to manage DHCP clients relinquishing their leases
  - `handle_packet/4` to generically handle DHCP packets
    - this is most useful to monitor how other DHCP servers are responding on your network

  Each of these DHCP callbacks take four arguments, in order:

  1. the fully-parsed `ExDhcp.Packet` structure,
  2. the _**xid**_ (transaction id)
  3. the _**mac address**_ of the client
  4. the current _**state**_ of the ExDhcp GenServer

  These are provided as arguments to enable you to easily trap their contents
  in pattern-matching guards.

  _NB: the `ExDhcp.Packet` structure has an `:options` field, and you
  may want to emit tags that are outside of the provided `basic dhcp` options
  (see `ExDhcp.Options.Basic`).  In this case, you should implement your
  own parser module (see `ExDhcp.Options.Macro`) and instrument it into your
  ExDhcp module using the `:dhcp_options` option like so:_

  ```elixir
    use Dhcp, dhcp_options: [ExDhcp.Options.Basic, YourParserModule, AnotherParserModule]
  ```

  ExDhcp also provides these optional callbacks
  - `handle_call/3`
  - `handle_cast/2`
  - `handle_continue/2`
  - `handle_info/2`

  These operate identically to their counterparts in `GenServer`, but note that they are passed
  their encapsulated state, not the raw state of the GenServer.
  """

  use GenServer

  alias ExDhcp.Packet
  alias ExDhcp.Utils

  require Logger

  defmacro __using__(opts) do

    {ct_opts, mod_opts} = if opts[:dhcp_options] do
      Keyword.split(opts, [:dhcp_options])
    else
      {[dhcp_options: [ExDhcp.Options.Basic]], opts}
    end

    quote do
      @behaviour ExDhcp

      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(mod_opts)))
      end

      def start_link(initial_state, options \\ []) do
        ExDhcp.start_link(__MODULE__, initial_state, options)
      end

      defoverridable child_spec: 1, start_link: 1, start_link: 2

      @doc false
      @spec options_parsers() :: [module]
      def options_parsers do
        unquote(ct_opts[:dhcp_options])
      end
    end
  end

  @internal_opts [:port, :bind, :client_port, :broadcast_addr]
  @default_port 6767      # assume we're not running as root.
  @default_client_port 68
  @default_broadcast_addr {255, 255, 255, 255}

  @doc """
  Caller function initiating the spawning of your ExDhcp GenServer.

  You may supply the following extra options:

  - `:port` the UDP port you'd like ExDhcp to listen in on; defaults to `6767`.
    you may want to change this to `67` if you do not want to use iptables to
    redirect DHCP transactions to a nonprivileged Elixir server.

  - `:bind_to_device` (must be a binary string), the device you would like to
    bind to for DHCP listening.

      - This is most useful when you have a device with a internal-and
      -external-facing net interfaces and you would like to only respond to DHCP
      requests coming from select directions.

      - This requires `cap_net_raw` to be set. In Linux systems, this is settable as
      superuser using the following command:

          ```bash
          setcap cap_net_raw=ep /path/to/beam.smp
          ```

  - `:client_port` specify a nonstandard port to send the response to.  Most
    useful for testing purposes; defaults to `68`.

  - `:broadcast_addr` to specify a nonstandard address for responses.
    Defaults to `{255, 255, 255, 255}`.

  See `GenServer.start_link/3` for further options.
  """
  def start_link(module, initializer, options \\ []) do

    {internal_opts, gen_server_opts} = Keyword.split(options, @internal_opts)

    GenServer.start_link(
      __MODULE__,
      {module, initializer, internal_opts},
      gen_server_opts)
  end

  @typedoc false
  @type state :: %{
    module: module,
    state: term,
    socket: :gen_udp.socket,
    client_port: 1..32_767,
    broadcast_addr: Utils.ip4
  }

  @spec init({module, term, keyword}) ::
    {:ok, state} | :ignore | {:stop, reason :: any}

  @impl true
  def init({module, initializer, opts}) do
    # use gen_udp to begin forwarding messages.
    port = opts[:port] || @default_port
    bind_opt = Keyword.take(opts, [:bind_to_device])
    client_port = opts[:client_port] || @default_client_port
    broadcast_addr = opts[:broadcast_addr] || @default_broadcast_addr

    # consider adding the bind device in.
    udp_opts = [:binary, active: true, broadcast: true] ++ bind_opt

    with {:ok, state} <- module.init(initializer),
         {:ok, socket} <- :gen_udp.open(port, udp_opts) do

      {:ok, %{module: module,
              state: state,
              socket: socket,
              client_port: client_port,
              broadcast_addr: broadcast_addr}}
      # on any other value obtained from attempting to initialize the
      # module, we return those errors transparently to cause the
      # initialization to fail.
    end
  end

  #######################################################################
  ## callback overrides

  @doc "See `GenServer.handle_info/2`"
  @callback handle_info(term, state) ::
    {:noreply, new_state :: state}
    | {:noreply, new_state :: state, timeout | :hibernate | {:continue, term}}
    | {:stop, reason :: term, new_state :: state}

  # DHCP magic cookie to select only UDP packets that are DHCP.
  @magic_cookie <<0x63, 0x82, 0x53, 0x63>>
  # DHCP options.  These raw values are implemented so that you can use
  # either parsed or unparsed versions of the options list.
  @message_type 53
  @dhcp_discover 1
  @dhcp_request 3
  @dhcp_decline 4
  @dhcp_release 7
  @dhcp_inform 8

  @impl true
  def handle_info(msg = {:udp, _, _, _, <<_::1888>> <> @magic_cookie <> _},
                  state = %{module: module}) do
    msg
    |> Packet.decode(module.options_parsers())
    |> packet_switch(state)
    |> process_action(state)
  end
  # handle other types of information that get sent to server.
  def handle_info(msg, state = %{module: module}) do
    if function_exported?(module, :handle_info, 2) do
      case module.handle_info(msg, state.state) do
        {:noreply, new_state}      -> {:noreply, %{state | state: new_state}}
        {:noreply, new_state, any} -> {:noreply, %{state | state: new_state}, any}
        {:stop, reason, new_state} -> {:stop, reason, %{state | state: new_state}}
      end
    else
      Logger.warn("undefined handle_info in #{module}")
      {:noreply, state}
    end
  end

  @dhcp_request_op 1

  defp packet_switch(pack, state), do: packet_switch(pack, pack.options, state)
  # versions that are parsed by Options.Basic
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{message_type: :discover}, state) do
     handle_discover_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{message_type: :request}, state) do
     handle_request_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{message_type: :decline}, state) do
     handle_decline_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{message_type: :release}, state) do
     handle_release_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{message_type: :inform}, state) do
     handle_inform_impl(pack, state)
  end
  # unparsed versions
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{@message_type => <<@dhcp_discover>>}, state) do
    handle_discover_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{@message_type => <<@dhcp_request>>}, state) do
    handle_request_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{@message_type => <<@dhcp_decline>>}, state) do
    handle_decline_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{@message_type => <<@dhcp_release>>}, state) do
    handle_release_impl(pack, state)
  end
  defp packet_switch(pack = %{op: @dhcp_request_op}, %{@message_type => <<@dhcp_inform>>}, state) do
    handle_inform_impl(pack, state)
  end
  defp packet_switch(pack, %{}, state), do: handle_packet_impl(pack, state)

  #############################################################################
  ## dhcp-specific event handling implementation

  @typedoc """
  DHCP callbacks should provide either a `:respond` or `:norespond` outcome.

  - In the case of the `:respond` outcome, a UDP response is sent over the
  open port earmarked for the specified mac address.

  - The `:norespond` outcome is a no-op.  No information is sent over the wire,
  and the client may choose to either continue sending requests on the
  presumption that the UDP packets were dropped, or initiate an entirely new
  transaction.
  """
  @type response ::
    {:respond, Packet.t, new_state :: term} |
    {:norespond, new_state :: any} |
    {:stop, reason :: term, new_state :: term}

  defp handle_discover_impl(p, state = %{module: module}) do
    module.handle_discover(p, p.xid, p.chaddr, state.state)
  end
  defp handle_request_impl(p, state = %{module: module}) do
    module.handle_request(p, p.xid, p.chaddr, state.state)
  end
  defp handle_decline_impl(p, state = %{module: module}) do
    module.handle_decline(p, p.xid, p.chaddr, state.state)
  end
  defp handle_release_impl(p, state = %{module: module}) do
    if function_exported?(module, :handle_release, 4) do
      module.handle_release(p, p.xid, p.chaddr, state.state)
    else
      {:norespond, state.state}
    end
  end
  defp handle_inform_impl(p, state = %{module: module}) do
    if function_exported?(module, :handle_inform, 4) do
      module.handle_inform(p, p.xid, p.chaddr, state.state)
    else
      {:norespond, state.state}
    end
  end
  defp handle_packet_impl(p, state = %{module: module}) do
    if function_exported?(module, :handle_packet, 4) do
      module.handle_packet(p, p.xid, p.chaddr, state.state)
    else
      {:norespond, state.state}
    end
  end

  @spec process_action(
    {:respond, Packet.t, term} | {:norespond, term} |{:stop, term, term},
    state) :: {:noreply, state} | {:stop, term, state}
  # common interface for handling respond, norespond, or stop
  # directives that are emitted by the handle_* callbacks.
  defp process_action({:respond, response, new_state}, state) do
    payload = Packet.encode(response)
    :gen_udp.send(state.socket, state.broadcast_addr, state.client_port, payload)
    {:noreply, %{state | state: new_state}}
  end
  defp process_action({:norespond, new_state}, state) do
    {:noreply, %{state | state: new_state}}
  end
  defp process_action({:stop, reason, new_state}, state) do
    {:stop, reason, %{state | state: new_state}}
  end

  @doc """
  Invoked on the new DHCP server process when started by `ExDhcp.start_link/3`

  Will typically emit `{:ok, state}`, where `state` is the initial state
  you expect to be contained within your ExDhcp GenServer.
  """
  @callback init(term) ::
    {:ok, term}
    | {:ok, term, timeout | :hibernate | {:continue, term}}
    | :ignore
    | {:stop, reason :: any}

  @doc """
  Responds to the DHCP discover query, as encoded in _option 53_.
  """
  @callback handle_discover(
    packet::Packet.t,
    xid::non_neg_integer,
    mac_addr::Utils.mac,
    state::term) :: response

  @doc """
  Responds to the DHCP inform query, as encoded in _option 53_.
  Defaults to ignore.
  """
  @callback handle_inform(
    packet::Packet.t,
    xid::non_neg_integer,
    mac_addr::Utils.mac,
    state::term) :: response

  @doc """
  Responds to the DHCP release query, as encoded in _option 53_.
  Defaults to ignore.
  """
  @callback handle_release(
    packet::Packet.t,
    xid::non_neg_integer,
    mac_addr::Utils.mac,
    state::term) :: response

  @doc """
  Responds to the DHCP request query, as encoded in _option 53_.
  """
  @callback handle_request(
    packet::Packet.t,
    xid::non_neg_integer,
    mac_addr::Utils.mac,
    state::term)  :: response

  @doc """
  Responds to the DHCP decline query, as encoded in _option 53_.
  """
  @callback handle_decline(
    packet::Packet.t,
    xid::non_neg_integer,
    mac_addr::Utils.mac,
    state::term)  :: response

  @doc """
  Responds to other DHCP queries or broadcast packets that might have floated
  past the server.

  There are situations where a DHCP request might have been
  handled by another server already and broadcasted over the layer 2 network.
  To avoid awkward leader contention or race conditions, your server may want
  to take actions in its internal state based on the information transmitted
  in these packets.  Use this callback to implement these features.

  Typically, the server queries you might want to monitor are:

  - DHCP_OFFER (2)
  - DHCP_ACK (5)
  - DHCP_NAK (6)

  If you override the use of `ExDhcp.Options.Basic`, your DHCP options parser may
  have overwritten _option 53_ with a different atom/value assignment scheme.  In
  this case, you should use also use a custom `handle_packet` routine.
  """
  @callback handle_packet(
    packet::Packet.t,
    xid::non_neg_integer,
    mac_addr::Utils.mac,
    state::term)  :: response

  #############################################################################
  # degenerate handlers
  #
  # these handlers merely intercept and forward GenServer functionality so that
  # you can treat your DHCP server as a fully OTP-compliant GenServer.

  @doc "See `GenServer.handle_call/3`"
  @callback handle_call(term, from::GenServer.from, state::term) ::
    {:reply, reply :: term, new_state::term}
    | {:reply, reply :: term, new_state::term, timeout | :hibernate | {:continue, term}}
    | {:noreply, new_state::term}
    | {:noreply, new_state::term, timeout | :hibernate | {:continue, term}}
    | {:stop, reason::term, reply :: term, new_state::term}
    | {:stop, reason::term, new_state::term}

  @impl true
  def handle_call(request, from, state = %{module: module}) do
    if function_exported?(module, :handle_call, 3) do
      case module.handle_call(request, from, state.state) do
        {:reply, reply, new_state} ->
          {:reply, reply, %{state | state: new_state}}
        {:reply, reply, new_state, any} ->
          {:reply, reply, %{state | state: new_state}, any}
        {:noreply, new_state} ->
          {:noreply, %{state | state: new_state}}
        {:noreply, new_state, any} ->
          {:noreply, %{state | state: new_state}, any}
        {:stop, reason, reply, new_state} ->
          {:stop, reason, reply, %{state | state: new_state}}
        {:stop, reason, new_state} ->
          {:stop, reason, %{state | state: new_state}}
      end
    else
      Logger.warn("undefined handle_call in #{module}")
      {:noreply, state}
    end
  end

  @doc "See `GenServer.handle_cast/2`"
  @callback handle_cast(request::term, state::term) ::
    {:noreply, new_state :: term}
    | {:noreply, new_state :: term, timeout | :hibernate | {:continue, term}}
    | {:stop, reason :: term, new_state :: term}

  @impl true
  def handle_cast(request, state = %{module: module}) do
    if function_exported?(module, :handle_cast, 2) do
      case module.handle_cast(request, state.state) do
        {:noreply, new_state} ->
          {:noreply, %{state | state: new_state}}
        {:noreply, new_state, any} ->
          {:noreply, %{state | state: new_state}, any}
        {:stop, reason, new_state} ->
          {:stop, reason, %{state | state: new_state}}
      end
    else
      Logger.warn("undefined handle_cast in #{module}")
      {:noreply, state}
    end
  end

  @doc "See `GenServer.handle_continue/2`"
  @callback handle_continue(continue :: term, state :: term) ::
    {:noreply, new_state :: term}
    | {:noreply, new_state :: term, timeout | :hibernate | {:continue, term}}
    | {:stop, reason :: term(), new_state :: term}

  @impl true
  def handle_continue(request, state = %{module: module}) do
    if function_exported?(module, :handle_continue, 2) do
      case module.handle_continue(request, state.state) do
        {:noreply, new_state} ->
          {:noreply, %{state | state: new_state}}
        {:noreply, new_state, any} ->
          {:noreply, %{state | state: new_state}, any}
        {:stop, reason, new_state} ->
          {:stop, reason, %{state | state: new_state}}
      end
    else
      Logger.warn("undefined handle_continue in #{module}")
      {:noreply, state}
    end
  end

  @doc "See `GenServer.terminate/2`"
  @callback terminate(condition :: :normal | :shutdown | {:shutdown, term},
                      state :: term) :: term

  @impl true
  def terminate(reason, state = %{module: module}) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, state.state)
    end
  end

  @optional_callbacks handle_inform: 4, handle_release: 4, handle_packet: 4,
                      handle_call: 3, handle_cast: 2, handle_info: 2,
                      handle_continue: 2, terminate: 2

end
