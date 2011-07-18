-module(erlfaye_api).
-author('antoniogarrote@gmail.com').
-include("erlycomet.hrl").
-include_lib("stdlib/include/qlc.hrl").


%% API
-export([add_connection/2,
         replace_connection/3,
         replace_connection/4,
         replace_connection_ws/3,
         replace_connection_ws/4,
         connections/0,
         connection/1,
         connection_pid/1,
         connection_by_client_pid/1,
         connection_by_websocket_pid/1,
         remove_connection/1,
         generate_id/0,
         subscribe/2,
         unsubscribe/2,
         subscribe_process/2,
         unsubscribe_process/2,
         channels/0,
         deliver_to_connection/2,
         deliver_to_connection/3,
         deliver_to_channel/2,
         cache_loop/2,
         delete_connection/1]).

%%====================================================================
%% cache process
%%====================================================================

cache_loop(Events, TransportPid) ->
    receive
        {event, Event}  ->
            error_logger:warning_msg(">>>> CACHE EVENT ~p  TransportPid ~p ~n",[Event, TransportPid]),
            if 
                TransportPid =/= 0 ->
                    error_logger:warning_msg(">>>> CACHE HINTING TRANSPORT ~p  ~n",[TransportPid]),
                    TransportPid ! hint;
                true  ->
                    error_logger:warning_msg(">>>> CACHE NOT HINTING TRANSPORT  ~p ~n",[TransportPid])
            end,
            error_logger:warning_msg(">>>> CACHE LOOPING IN EVENT ~n",[]),   
            cache_loop([Event | Events], TransportPid);
        flush ->
            error_logger:warning_msg(">>>> CACHE FLUSH  ~n",[]),
            TransportPid ! {cachedEvents, lists:reverse(Events)},
            cache_loop([], TransportPid);            
        {setpid, Pid}   ->
            error_logger:warning_msg(">>>> CACHE SETID  ~p~n",[Pid]),
            cache_loop(Events, Pid);
        disconnect ->
            done
    end.
 

%%====================================================================
%% API
%%====================================================================
%%-------------------------------------------------------------------------
%% @spec (string(), pid()) -> ok | error 
%% @doc
%% adds a connection
%% @end
%%-------------------------------------------------------------------------
add_connection(ClientId, Pid) -> 
    E = #connection{client_id=ClientId, pid=Pid},
    F = fun() -> mnesia:write(E) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.

%%-------------------------------------------------------------------------
%% @spec (string(), pid()) -> {ok, new} | {ok, replaced} | error 
%% @doc
%% Adds a local process to some channel
%% @end
%%-------------------------------------------------------------------------

subscribe_process(Pid,Channel) -> 
    case connection_by_client_pid(Pid)  of
        undefined ->
            ClientId = generate_id(),
            E = #connection{client_id=ClientId, pid=Pid, cache_pid=Pid, state=connected, websocket_pid=Pid},    
            case mnesia:transaction(fun() -> mnesia:write(E) end) of
                {atomic, ok} -> 
                    subscribe(ClientId,Channel),
                    ok;
                _ -> error
            end;
        #connection{client_id=ClientId}  ->
            subscribe(ClientId,Channel),
            ok
    end.

unsubscribe_process(Pid,Channel) -> 
    case connection_by_client_pid(Pid)  of
        undefined ->
            error;
        #connection{client_id=ClientId}  ->
            unsubscribe(ClientId,Channel),
            ok
    end.                                                       
            

%%-------------------------------------------------------------------------
%% @spec (string(), pid()) -> {ok, new} | {ok, replaced} | error 
%% @doc
%% replaces a connection
%% @end
%%-------------------------------------------------------------------------
replace_connection(ClientId, Pid, NewState) -> 
    replace_connection(ClientId, Pid, 0, NewState).
replace_connection(ClientId, Pid, CachePid, NewState) -> 
    E = #connection{client_id=ClientId, pid=Pid, state=NewState, websocket_pid=0},
    F1 = fun() -> mnesia:read({connection, ClientId}) end,
    {Status, F2} = case mnesia:transaction(F1) of
                       {atomic, EA} ->
                           error_logger:warning_msg("READ FROM MNESIA ~p~n",[EA]),
                           case EA of
                               [] ->
                                   ECPid = E#connection{cache_pid=CachePid},
                                   {new, fun() -> mnesia:write(ECPid) end};
                               [#connection{state=State, websocket_pid=WebsocketPid, cache_pid=ActualCachePid}] ->
                                   ECPid = E#connection{cache_pid=ActualCachePid, websocket_pid=WebsocketPid},
                                   case State of
                                       handshake ->
                                           {replaced_hs, fun() -> mnesia:write(ECPid) end};
                                       _ ->
                                           {replaced, fun() -> mnesia:write(ECPid) end}
                                   end
                           end;
                       _ ->
                           {new, fun() -> mnesia:write(E) end}
                   end,

    case mnesia:transaction(F2) of
        {atomic, ok} -> {ok, Status};
        _ -> error
    end.

replace_connection_ws(ClientId, Pid, NewState) -> 
    replace_connection_ws(ClientId, Pid, 0, NewState).
replace_connection_ws(ClientId, Pid, CachePid, NewState) -> 
    E = #connection{client_id=ClientId, pid=Pid, state=NewState, websocket_pid=Pid},
    F1 = fun() -> mnesia:read({connection, ClientId}) end,
    {Status, F2} = case mnesia:transaction(F1) of
                       {atomic, EA} ->
                           case EA of
                               [] ->
                                   ECPid = E#connection{cache_pid=CachePid},
                                   {new, fun() -> mnesia:write(ECPid) end};
                               [#connection{state=State, cache_pid=ActualCachePid}] ->
                                   ECPid = E#connection{cache_pid=ActualCachePid},
                                   case State of
                                       handshake ->
                                           {replaced_hs, fun() -> mnesia:write(ECPid) end};
                                       _ ->
                                           {replaced, fun() -> mnesia:write(ECPid) end}
                                   end
                           end;
                       _ ->
                           {new, fun() -> mnesia:write(E) end}
                   end,

    case mnesia:transaction(F2) of
        {atomic, ok} -> {ok, Status};
        _ -> error
    end.
       
          
%%--------------------------------------------------------------------
%% @spec () -> list()
%% @doc
%% returns list of connections
%% @end 
%%--------------------------------------------------------------------    
connections() -> 
    do(qlc:q([X || X <-mnesia:table(connection)])).
  
connection(ClientId) ->
    F = fun() -> mnesia:read({connection, ClientId}) end,
    case mnesia:transaction(F) of
        {atomic, Row} ->
            case Row of
                [] -> undefined;
                [Conn] -> Conn
            end;
        _ ->
            undefined
    end.

connection_by_client_pid(Pid) ->
    case do(qlc:q([X || X <-mnesia:table(connection),
                        X#connection.pid == Pid])) of
        [] ->
            undefined;
        [Connection] -> Connection
    end.

connection_by_websocket_pid(Pid) ->
    case do(qlc:q([X || X <-mnesia:table(connection),
                        X#connection.websocket_pid == Pid])) of
        [] ->
            undefined;
        [Connection] -> Connection
    end.

%%--------------------------------------------------------------------
%% @spec (string()) -> pid()
%% @doc 
%% returns the PID of a connection if it exists
%% @end 
%%--------------------------------------------------------------------    
connection_pid(ClientId) ->
    case connection(ClientId) of
        #connection{pid=Pid} -> Pid;
        undefined -> undefined
    end.    

connection_event_receiver_pid(ClientId) ->
    case connection(ClientId) of
        #connection{cache_pid=CachePid, websocket_pid=0} ->
            error_logger:warning_msg("EVENT RECEIVER IS CACHE: ~p ~n",[CachePid]),        
            CachePid;
        #connection{websocket_pid=WebsocketPid} -> 
            error_logger:warning_msg("EVENT RECEIVER IS WEBSOCKET: ~p ~n",[WebsocketPid]),        
            WebsocketPid;
        undefined -> 
            undefined
    end.    

%%--------------------------------------------------------------------
%% @spec (string()) -> ok | error  
%% @doc
%% removes a connection
%% @end 
%%--------------------------------------------------------------------  
remove_connection(ClientId) ->
    F = fun() -> mnesia:delete({connection, ClientId}) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.    


%%--------------------------------------------------------------------
%% @spec (string(), string()) -> ok | error 
%% @doc
%% subscribes a client to a channel
%% @end 
%%--------------------------------------------------------------------
subscribe(ClientId, ChannelName) ->
    F = fun() ->
        Channel = case mnesia:read({channel, ChannelName}) of
            [] -> 
                #channel{name=ChannelName, client_ids=[ClientId]};
            [#channel{client_ids=[]}=Channel1] ->
                Channel1#channel{client_ids=[ClientId]};
            [#channel{client_ids=Ids}=Channel1] ->
                Channel1#channel{client_ids=[ClientId | Ids]}
        end,
        mnesia:write(Channel)
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.
    
    
%%--------------------------------------------------------------------
%% @spec (string(), string()) -> ok | error  
%% @doc
%% unsubscribes a client from a channel
%% @end 
%%--------------------------------------------------------------------
unsubscribe(ClientId, ChannelName) ->
    F = fun() ->
        case mnesia:read({channel, ChannelName}) of
            [] ->
                {error, channel_not_found};
            [#channel{client_ids=Ids}=Channel] ->
                mnesia:write(Channel#channel{client_ids = lists:delete(ClientId,  Ids)})
        end
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        _ -> error
    end.

delete_connection(ClientId) ->
    F = fun() ->
                mnesia:delete(ClientId)
        end,
    case mnesia:transaction(F) of
        {atomic,ok} ->
            ok;
        _ ->
            error
    end.

%%--------------------------------------------------------------------
%% @spec () -> list()
%% @doc
%% returns a list of channels
%% @end 
%%--------------------------------------------------------------------
channels() ->
    do(qlc:q([X || X <-mnesia:table(channel)])).


%%--------------------------------------------------------------------
%% @spec (string(), string(), tuple()) -> ok | {error, connection_not_found} 
%% @doc
%% delivers data to one connection
%% @end 
%%--------------------------------------------------------------------  
deliver_to_connection(ClientId, Event) ->
    F = fun() -> mnesia:read({connection, ClientId}) end,
    case mnesia:transaction(F) of 
        {atomic, []} ->
            {error, connection_not_found};
        {atomic, [#connection{cache_pid=CachePid}]} -> 
            CachePid ! {event, Event},
            ok
    end.


%%--------------------------------------------------------------------
%% @spec (string(), string(), tuple()) -> ok | {error, connection_not_found} 
%% @doc
%% delivers data to one connection
%% @end 
%%--------------------------------------------------------------------  
deliver_to_connection(ClientId, Channel, Data) ->
    Event = {struct, [{channel, Channel},  {data, Data}]},
    F = fun() -> mnesia:read({connection, ClientId}) end,
    case mnesia:transaction(F) of 
        {atomic, []} ->
            {error, connection_not_found};
        {atomic, [#connection{cache_pid=CachePid}]} -> 
            CachePid ! {event, Event},
            ok
    end.
    

%%--------------------------------------------------------------------
%% @spec  (string(), tuple()) -> ok | {error, channel_not_found} 
%% @doc
%% delivers data to all connections of a channel
%% @end 
%%--------------------------------------------------------------------
deliver_to_channel(Channel, Data) ->
    globbing(fun deliver_to_single_channel/2, Channel, Data).
    

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

globbing(Fun, Channel, Data) ->
    case lists:reverse(binary_to_list(Channel)) of
        [$*, $* | T] ->
            lists:map(fun
                    (X) ->
                        case string:str(X, lists:reverse(T)) of
                            1 ->
                                Fun(Channel, Data);
                            _ -> 
                                skip
                        end                        
                end, channels());
        [$* | T] ->
            lists:map(fun
                    (X) ->
                        case string:str(X, lists:reverse(T)) of
                            1 -> 
                                Tokens = string:tokens(string:sub_string(X, length(T) + 1), "/"),
                                case Tokens of
                                    [_] ->
                                        Fun(Channel, Data);
                                    _ ->
                                        skip
                                end;
                            _ -> 
                                skip
                        end                        
                end, channels());
        _ ->
            Fun(Channel, Data)
    end.


deliver_to_single_channel(Channel, Data) ->            
    Event = {struct, [{channel, Channel}, {data, Data}]},                    
    F = fun() -> mnesia:read({channel, Channel}) end,
    Channels = mnesia:transaction(F),
    case Channels of 
        {atomic, [{channel, Channel, []}] } -> 
            error_logger:warning_msg("NOT HANDLERS FOUND FOR CHANNEL: ~p ~n",[Channel]),        
            ok;
        {atomic, [{channel, Channel, Ids}] } ->
            [send_event(connection_event_receiver_pid(ClientId), Event) || ClientId <- Ids],
            ok; 
        _ ->
            {error, channel_not_found}
     end.
     

send_event(CachePid, Event) when is_pid(CachePid)->
    CachePid ! {event, Event};
send_event(_, _) ->
    ok.


do(QLC) ->
    F = fun() -> qlc:e(QLC) end,
    {atomic, Val} = mnesia:transaction(F),
    Val.


generate_id() ->
    <<Num:128>> = crypto:rand_bytes(16),
    [HexStr] = io_lib:fwrite("~.16B",[Num]),
    MaybePid = list_to_binary(HexStr),
    case erlfaye_api:connection_pid(MaybePid) of
        undefined ->
            MaybePid;
    _ ->
        generate_id()
    end.
