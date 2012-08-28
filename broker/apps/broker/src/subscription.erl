%%%-------------------------------------------------------------------
%%% File : subscription.erl
%%% Author : Son Tran <sntran@koding.com>
%%% Description : A gen_server to handle request within an exchange of
%%% a specific client.
%%%
%%% Created : 27 August 2012 by Son Tran <sntran@koding.com>
%%%-------------------------------------------------------------------
-module(subscription).
-behaviour(gen_server).
%% API
-export([start_link/4, bind/2, unbind/2, trigger/4, notify_first/3]).
%% gen_server callbacks
-export([init/1, terminate/2, code_change/3,
        handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {connection, channel, 
        exchange, client, private,
        bindings = dict:new(), sender}).

-define (SERVER, ?MODULE).
-define (MESSAGE_TTL, 5000).
-include_lib("amqp_client/include/amqp_client.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link(Connection, Client, Conn, Exchange) -> 
%%                          {ok,Pid} | ignore | {error,Error}
%% Types: 
%%  Connection = pid(),
%%  Client = pid(),
%%  Conn = sockjs_connection(),
%%  Exchange = binary().
%%
%% Description: Starts the subscription server.
%%  Connection is the broker connection to MQ.
%%  Client is the PID of the client whose request was made.
%%  Conn is the sockjs_connection used to send message.
%%  Exchange is the name of the exchange to connect to.
%%--------------------------------------------------------------------
start_link(Connection, Client, Conn, Exchange) ->
    gen_server:start_link(?MODULE, [Connection, Client, Conn, Exchange], []).

bind(Subscription, Event) ->
    gen_server:call(Subscription, {bind, Event}).

unbind(Subscription, Event) ->
    gen_server:call(Subscription, {unbind, Event}).

trigger(Subscription, Event, Payload, Meta) ->
    gen_server:call(Subscription, {trigger, Event, Payload, Meta}).

change_exchange(Subscription, Exchange) ->
    gen_server:call(Subscription, {change, Exchange}).

rpc(Subscription, RoutingKey, Payload) ->
    gen_server:call(Subscription, {rpc, RoutingKey, Payload}).


%%====================================================================
%% gen_server callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%% {ok, State, Timeout} |
%% ignore |
%% {stop, Reason}
%% Description: Initiates the server, arguments are passed by third arg
%% in gen_server:start_link call
%%--------------------------------------------------------------------
init([Connection, Client, Conn, Exchange]) ->
    process_flag(trap_exit, true),

    SendFun = fun (Data) -> send(Conn, Exchange, Data) end,

    {ok, Channel} = channel(Connection),
    Private = is_private(Exchange),
    spawn(?MODULE, notify_first, [SendFun, channel(Connection), Exchange]),

    State = #state{ connection = Connection,
                    channel = Channel,
                    exchange = Exchange,
                    private = Private,
                    client = Client,
                    sender = SendFun},

    try subscribe(SendFun, Channel, Exchange) of
        ok -> {ok, State}
    catch
        error:precondition_failed ->
            NewChannel = channel(Connection),
            % TODO: Close the subscription
            ErrMsg = get_env(precondition_failed, <<"Unknow error">>),
            SendFun([<<"broker:subscription_error">>, ErrMsg]),
            {stop, precondition_failed}
    end.

%%--------------------------------------------------------------------
%% Function: %% handle_call({bind, Event}, From, State) 
%%                      -> {noreply, State}.
%% Types:
%%  Event = binary(),
%%  From = pid(),
%%  State = #state{}
%% Description: Handling key binding to the exchange.
%%--------------------------------------------------------------------
handle_call({bind, Event}, From, State=#state{channel=Channel,
                                                exchange=Exchange,
                                                bindings=Bindings}) ->
    % Ensure one queue per key per exchange
    case dict:find(Event, Bindings) of
        {ok, _Queue} -> {reply, ok, State};
        error ->
            Queue = bind_queue(Channel, Exchange, Event),
            NewBindings = dict:store(Event, Queue, Bindings),
            {reply, ok, State#state{bindings = NewBindings}}
    end;

%%--------------------------------------------------------------------
%% Function: %% handle_call({unbind, Event}, From, State) 
%%                      -> {noreply, State}.
%% Types:
%%  Event = binary(),
%%  From = pid(),
%%  State = #state{}
%% Description: Handling key unbinding from the exchange.
%%--------------------------------------------------------------------
handle_call({unbind, Event}, From, State=#state{channel=Channel,
                                                exchange=Exchange,
                                                bindings=Bindings}) ->
    case dict:find(Event, Bindings) of 
        {ok, Queue} ->
            unbind_queue(Channel, Exchange, Event, Queue),
            % Remove from the dictionary
            NewBindings = dict:erase(Event, Bindings),
            {reply, ok, State#state{bindings = NewBindings}};
        error ->
            {reply, ok, State}
    end;

%%--------------------------------------------------------------------
%% Function: %% handle_call({trigger, Event, Payload}, From, State) 
%%                      -> {noreply, State}.
%% Types:
%%  Event = binary(),
%%  Payload = bitstring(),
%%  Meta = [Props],
%%  Props = {<<"replyTo">>, ReplyTo} || TBA
%%  ReplyTo = binary(),
%%  From = pid(),
%%  State = #state{}
%% Description: Handling key unbinding from the exchange.
%%--------------------------------------------------------------------
handle_call({trigger, Event, Payload, Meta}, From, 
            State=#state{channel=Channel,
                        exchange=Exchange,
                        private=Private}) ->
    case Private of 
        true -> 
            broadcast(From, Channel, Exchange, Event, Payload, Meta),
            {reply, ok, State};
        false -> {reply, ok, State}
    end;

%%--------------------------------------------------------------------
%% Function: %% handle_call({subscribe, Exchange}, From, State) 
%%                      -> {noreply, State}.
%% Types:
%%  Exchange = pid(),
%%  From = pid(),
%%  State = #state{}
%% Description: Handling new subscription.
%%--------------------------------------------------------------------
handle_call({rpc, RoutingKey, Payload}, _From, State) ->
    RpcClient = amqp_rpc_client:start(self(), RoutingKey),
    io:format("RpcClient ~p~n", [RpcClient]),
    amqp_rpc_client:call(RpcClient, list_to_binary(Payload)),
    {noreply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.
    
%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%% {noreply, State, Timeout} |
%% {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.
    
%%--------------------------------------------------------------------
%% Function: handle_info(#'basic.consume_ok'{}, State) -> 
%%                                          {noreply, State}
%% Description: Acknowledge the subscription from MQ.
%%--------------------------------------------------------------------
handle_info(#'basic.consume_ok'{}, State) -> 
    io:format("start consuming~n"),
    {noreply, State};

%%--------------------------------------------------------------------
%% Function: handle_info({Deliver, Msg}, State) -> 
%%                                          {noreply, State}.
%% Types:
%%  Deliver = #'basic.deliver'{exchange = Exchange},
%%  Exchange = <<"KDPresence">>,
%%  Msg = #amqp_msg{props = Props},
%%  Props = #'P_basic'{headers = Headers}.
%%  Headers = proplist().
%% Description: Presence announcement
%%--------------------------------------------------------------------
handle_info({#'basic.deliver'{exchange = <<"KDPresence">>},
            #amqp_msg{props=#'P_basic'{headers = Headers}}}, State) ->
    [{<<"action">>, longstr, Action}, % "bind" || "unbind"
     {<<"exchange">>, longstr, XName}, % same as this excchange
     {<<"queue">>, longstr, QName}, % name of queue
     {<<"key">>, longstr, BindingKey}] = Headers,
    {noreply, State};

%%--------------------------------------------------------------------
%% Function: handle_info({Deliver, Msg}, State) -> 
%%                                          {noreply, State}.
%% Types:
%%  Deliver = #'basic.deliver'{routing_key = Key, exchange = Exchange},
%%  Key = binary(),
%%  Exchange = binary(),
%%  Msg = #amqp_msg{payload = Payload},
%%  Payload = bitstring(),
%% Description: Echo to the client receiving message from bound events.
%%--------------------------------------------------------------------
handle_info({#'basic.deliver'{routing_key = Event, exchange = Exchange}, 
            #amqp_msg{props =  #'P_basic'{correlation_id = CorId},
                payload = Payload}}, State=#state{sender=Sender}) ->
    Self = term_to_binary(self()),
    case CorId of 
        Self -> {noreply, State};
        _ -> 
            Sender([Event, Payload]),
            {noreply, State}
    end;

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%% {noreply, State, Timeout} |
%% {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    io:format("Receive somehting else~n"),
    {noreply, State}.
    
%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, #state{channel = Channel,
                            exchange = Exchange,
                            bindings = Bindings}) ->
    [unbind_queue(Channel, Exchange, Binding, Queue) || 
        {Binding, Queue} <- dict:to_list(Bindings)],
    amqp_channel:close(Channel),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

channel(Connection) ->
    amqp_connection:open_channel(Connection).

%%--------------------------------------------------------------------
%% Func: is_private(Exchange) -> boolean()
%% Description: Detect whether the exchange is private.
%%--------------------------------------------------------------------
is_private(Exchange) ->
    %RegExp = "^priv[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}",
    RegExp = ".private$",
    %Options = [{capture, [1], list}],

    case re:run(Exchange, RegExp) of
        {match, _}  -> true;
        nomatch     -> false
    end.

%%--------------------------------------------------------------------
%% Function: notify_first(Sender, Channel, Exchange) -> void()
%% Description: Perform a check for existence against an exchange and 
%% notify the Conn if the exchange does not exist.
%% This is a one-off function to be run in a separate process and exit
%% normally to avoid blocking the current process.
%%--------------------------------------------------------------------
notify_first(Sender, Channel, Exchange) ->
    Check = #'exchange.declare'{ exchange = Exchange,
                                    passive = true},
    try amqp_channel:call(Channel, Check) of
        #'exchange.declare_ok'{} -> exit(normal)
    catch exit:_Ex1 -> 
            Sender([<<"broker:first_connection">>, Exchange]),
            exit(normal)
    end.

%%--------------------------------------------------------------------
%% Function: subscribe(Conn, Channel, Queue) -> void()
%% Description: Declares the exchange and starts the receive loop
%% process. This process is used to subscribe to queue later on.
%% The exchange is marked durable so that it can survive server reset.
%% This broker has to have a way to delete the exchange when done.
%%--------------------------------------------------------------------
subscribe(Sender, Channel, Exchange) -> 
    Declare = #'exchange.declare'{  exchange = Exchange, 
                                    type = <<"topic">>,
                                    durable = true,
                                    auto_delete = true},

    try amqp_channel:call(Channel, Declare) of
        #'exchange.declare_ok'{} -> 
            Sender([<<"broker:subscription_succeeded">>, <<>>]),
            ok
    catch
        exit:Error ->
            handle_amqp_error(Error)
    end.

%%--------------------------------------------------------------------
%% Function: bind_queue(Channel, Exchange, Routing) -> pid()
%% Description: Declares a queue and bind to the routing key. Also
%% starts the subscription on that queue.
%%--------------------------------------------------------------------
bind_queue(Channel, Exchange, Routing) ->
    % Ensure the client has time to consume the message
    Args = [{<<"x-message-ttl">>, long, ?MESSAGE_TTL}],
    #'queue.declare_ok'{queue = Queue} =
        amqp_channel:call(Channel, #'queue.declare'{exclusive = true,
                                                    durable = true,
                                                    arguments = Args}),

    Binding = #'queue.bind'{exchange = Exchange,
                            routing_key = Routing,
                            queue = Queue},
    #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    Sub = #'basic.consume'{queue = Queue, no_ack = true},
    amqp_channel:subscribe(Channel, Sub, self()),
    Queue.

%%--------------------------------------------------------------------
%% Function: unbind_queue(Channel, Exchange, Routing, Queue) -> pid()
%% Description: Unbinds the queue from the routing key in the exchange
%% and deletes it.
%%--------------------------------------------------------------------
unbind_queue(Channel, Exchange, Routing, Queue) ->
    % Unbind the queue from the routing key
    Binding = #'queue.unbind'{  exchange    = Exchange,
                                routing_key = Routing,
                                queue       = Queue},
    #'queue.unbind_ok'{} = amqp_channel:call(Channel, Binding),
    % Delete the queue
    Delete = #'queue.delete'{queue = Queue},
    #'queue.delete_ok'{} = amqp_channel:call(Channel, Delete).

%%--------------------------------------------------------------------
%% Function: broadcast(From, Channel, Exchange, Event, Data, Meta) -> void()
%% Description: Set up the correlation id, then publish the Data to 
%% the Exchange on the routing key the same as the Event.
%%--------------------------------------------------------------------
broadcast(From, Channel, Exchange, Event, Data, Meta) ->
    Publish = #'basic.publish'{ exchange = Exchange, 
                                routing_key = Event},
    CorId = term_to_binary(From),

    case lists:keyfind(<<"replyTo">>, 1, Meta) of 
        {_, ReplyTo} -> 
            Props = #'P_basic'{correlation_id = CorId,
                                reply_to = ReplyTo},
            Msg = #amqp_msg{props = Props, payload = Data},
            amqp_channel:cast(Channel, Publish, Msg);
        false ->        
            Props = #'P_basic'{correlation_id = CorId},
            Msg = #amqp_msg{props = Props, payload = Data},
            amqp_channel:cast(Channel, Publish, Msg)
    end.

send(Conn, Exchange, [Key, Payload]) ->
    Event = {<<"event">>, Key},
    Channel = {<<"channel">>, Exchange},
    Data = {<<"payload">>, Payload},
    Conn:send(jsx:encode([Event, Channel, Data])).

handle_amqp_error({{shutdown, {_Reason, 406, _Msg}}, _Who}) ->
    error(precondition_failed).

get_env(Param, DefaultValue) ->
    case application:get_env(broker, Param) of
        {ok, Val} -> Val;
        undefined -> DefaultValue
    end.