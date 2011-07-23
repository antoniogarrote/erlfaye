-module(erlfaye_request).
-author('antoniogarrote@gmail.com').

%% API
-export([handle/1]).

-include("erlycomet.hrl").

-record(state, {
          id = undefined,
          connection_type,
          events = [],
          timeout = 300000,      %% 5 minutes
          callback = undefined}).  

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec
%% @doc handle POST / GET Comet messages
%% @end 
%%--------------------------------------------------------------------
handle(Req) ->
    handle(Req, Req:get(method)).

handle(Req, 'POST') ->
    ContentType = Req:get_primary_header_value("content-type"),
    if  
        ContentType == "application/json" ->
            process_bayeux_msg(Req, mochijson2:decode(Req:recv_body()), undefined);
        true ->
            handle(Req, Req:parse_post())
    end;
handle(Req, 'GET') ->
    case erlfaye_websockets_api:is_upgrade_request(Req) of
        true ->
            case erlfaye_websockets_api:try_to_upgrade(Req) of
                false     -> done;
                WebSocket ->
                    error_logger:warning_msg("WS (~p) UPDGRADING OK! ~n",[self()]),
                    websocket_loop(WebSocket),
                    done
            end;
        false ->
            handle(Req, Req:parse_qs())
    end;    
handle(Req, [{"message", Msg}, {"jsonp", Callback} | _]) ->
    case process_bayeux_msg(Req, mochijson2:decode(Msg), Callback) of
        done -> ok;
        [done] -> ok;
        Body -> 
            Resp = callback_wrapper(mochijson2:encode(Body), Callback),       
            Req:ok({"text/javascript", Resp})   
    end;       
handle(Req, [{"message", Msg} | _]) ->
    case process_bayeux_msg(Req, mochijson2:decode(Msg), undefined) of
        done -> ok;
        [done] -> ok;
        Body -> Req:ok({"text/json", mochijson2:encode(Body)})
    end;        
handle(Req, _) ->
    Req:not_found().

%%====================================================================
%% long polling connection process 
%%====================================================================

shouldQueue([]) ->
    true;
shouldQueue([{struct, Fields}]) ->
    case lists:keyfind(channel,1,Fields) of
        false ->
            false;
        {channel, <<"/meta/connect">>}  -> 
            true;
        _ -> false
    end;
shouldQueue([_H|_T]) ->
    false.
                
loop(Resp, #state{events=Events, id=Id} = State, CachePid, Callback) ->   

    % set up the connection between the cache and the client handler
    CachePid ! {setpid, self()},

    CachePid ! flush,

    receive
        {cachedEvents, CachedEvents} ->
            error_logger:warning_msg("********** CACHED EVENTS: ~p~n~p~n~n",[Id, CachedEvents]),
            AllEvents = CachedEvents++lists:reverse(Events),

            ShouldQueue = shouldQueue(AllEvents),
            error_logger:warning_msg("********** should queue?: ~p ~n -> ~n ~p~n~n",[AllEvents, ShouldQueue]),
            if 
                ShouldQueue == false ->
                    error_logger:warning_msg("********** SENDING: ~p~n~p~n~n",[Id,AllEvents]),
                    send(Resp, AllEvents, Callback),
                    exit(normal);
                ShouldQueue == true ->
                    receive
                        {hint,_} ->
                            error_logger:warning_msg("********** RECEIVED HINT: ~p~n",[Id]),
                            loop(Resp, State#state{events=AllEvents}, CachePid,Callback);                                  
                        stop ->  
                            error_logger:warning_msg("********** RECEIVED STOP: ~p~n",[Id]),
                            CachePid ! disconnect,
                            disconnect(Resp, Id, undefined, Callback);
                        {stop, MessageId} ->  
                            error_logger:warning_msg("********** RECEIVED STOP: ~p~n",[Id]),
                            CachePid ! disconnect,
                            disconnect(Resp, Id, MessageId, Callback)
                    after State#state.timeout ->
                            error_logger:warning_msg("********** DISCONECTING: ~p~n",[Id]),
                            CachePid ! disconnect,
                            disconnect(Resp, Id, undefined, Callback)
                    end
            end
    end.

send(Resp, Data, Callback) ->
    Chunk = callback_wrapper(mochijson2:encode(Data), Callback),
    Resp:write_chunk(Chunk),
    Resp:write_chunk([]).
    
    
disconnect(Resp, Id, MessageId, Callback) ->
    erlfaye_api:remove_connection(Id),
    L = {struct, [{channel, <<"/meta/disconnect">>}, {successful, true}, {clientId, Id}]},
    Msg = case MessageId of
              undefined  -> L ;
              _ -> [{id, MessageId} | L]
          end,
    Chunk = callback_wrapper(mochijson2:encode(Msg), Callback),
    Resp:write_chunk(Chunk),
    Resp:write_chunk([]),
    done.

%%====================================================================
%% web socket connection process 
%%====================================================================

websocket_loop(WebSocket) ->
    websocket_loop(WebSocket,0,[],0).
websocket_loop(WebSocket, MaybeCachePid, Cache,ClientId) ->
    if
        MaybeCachePid =/= 0 ->
            error_logger:warning_msg("WS (~p) FLUSHING CACHE ~p ~n",[self(), MaybeCachePid]),
            MaybeCachePid ! flush;
        true  ->
            error_logger:warning_msg("WS (~p) NOT FLUSHING CACHE ~p ~n",[self(), MaybeCachePid]),
            default
    end,

    receive
        {cachedEvents, CachedEvents} ->
            AllEvents = Cache ++ CachedEvents,
            error_logger:warning_msg("WS (~p) SENDING RECEIVED CACHED EVENTS ~p ~n",[self(),AllEvents]),
            [erlfaye_websockets_api:send_data(WebSocket,mochijson2:encode(Event)) || Event <- AllEvents],
            websocket_loop(WebSocket,MaybeCachePid,[],ClientId);            
        {hint, CachePid} ->
            error_logger:warning_msg("WS (~p) SENDING RECEIVED HINT FROM ~p ~n",[self(), CachePid]),
            CachePid ! flush,
            case MaybeCachePid of
                0 ->
                    error_logger:warning_msg("WS (~p) UPDATING CACHE PID ~p ~n",[self(), CachePid]),
                    websocket_loop(WebSocket,CachePid,Cache,ClientId);                    
                _ ->
                    websocket_loop(WebSocket,MaybeCachePid,Cache,ClientId)
            end;                
        {event, Event}  ->
            error_logger:warning_msg("WS (~p) SENDING RECEIVED EVENT ~n",[self(), Event]),
            erlfaye_websockets_api:send_data(WebSocket, mochijson2:encode(Event)),
            websocket_loop(WebSocket,MaybeCachePid,Cache,ClientId);
        {tcp_closed,_} ->
            error_logger:warning_msg("WS (~p) STOPPING WEBSOCKET PROCESS DUE TO REMOTE CLOSE EVENT ~n",[self()]),
            clean_websocket(self()),
            done;
        {tcp, _, Data} ->
            case Data of
                undefined ->
                    error_logger:warning_msg("WS (~p) GOT TCP DATA UNDEFINED ~n",[self()]),
                    receive
                        after 500 ->
                                websocket_loop(WebSocket,MaybeCachePid,Cache,ClientId)
                        end;
                _  ->            
                    JsonObj = lists:flatten(lists:map(fun (X) -> mochijson2:decode(X) end, erlfaye_websockets_api:unframe(binary_to_list(Data)))),
                    error_logger:warning_msg("WS (~p) GOT TCP DATA ~p ~n",[self(),JsonObj]),
                    {Results,CacheP,ClientIdPP} = case JsonObj of   
                                                      Array when is_list(Array) -> 
                                                          AllMessages = (lists:reverse(Cache)++Array),
                                                          error_logger:warning_msg("WS (~p) TRYING TO UPDATE CLIENTS... ~n",[self()]),
                                                          ClientIdP = update_connection_client_ws(ClientId,AllMessages),
                                                          Channels = [ get_json_map_val(<<"channel">>, X) || X <- AllMessages ],
                                                          error_logger:warning_msg("WS (~p) ALL CHANNELS: ~p ~n",[self(),Channels]),
                                                          case Channels of
                                                              [<<"/meta/connect">>] ->
                                                                  {[continue], [lists:nth(1,Array)|Cache], ClientIdP};
                                                              _ ->
                                                                  {[process_ws_cmd(WebSocket, get_json_map_val(<<"channel">>, X), X) || X <- (lists:reverse(Cache)++Array)], [], ClientIdP}
                                                          end
                                                  end,
                    case should_continue(Results) of
                        true  ->
                            websocket_loop(WebSocket,MaybeCachePid,CacheP,ClientIdPP);
                        false ->
                            clean_websocket(self()),
                            done
                    end
            end
    end.

update_connection_client_ws(0,[]) ->
    0;
update_connection_client_ws(0,[Struct|T]) ->
    error_logger:warning_msg("WS (~p) TRYING TO UPDATE CLIENTS SEARCHING IN ~p --> ~p ~n",[self(), Struct,get_json_map_val(<<"clientId">>, Struct)]),
    case get_json_map_val(<<"clientId">>, Struct) of
        undefined ->
            update_connection_client_ws(0,T);
        ClientId ->
            error_logger:warning_msg("WS (~p) TRYING TO UPDATE CLIENTS FOUND! replacing: ~n",[self()]),
            erlfaye_api:replace_connection_ws(ClientId, self(), connected),
            ClientId
    end;
update_connection_client_ws(ClientPid,_) ->
    ClientPid.

clean_websocket(Pid) ->
    case erlfaye_api:connection_by_websocket_pid(Pid) of
        undefined ->
            undefined;
        #connection{client_id=ClientId} ->
            erlfaye_api:delete_connection(ClientId)
    end.

%%====================================================================
%% Internal functions
%%====================================================================

process_bayeux_msg(Req, JsonObj, Callback) ->
    case JsonObj of   
        Array when is_list(Array) -> 
            [ process_msg(Req, X, Callback) || X <- Array ];
        Struct-> 
            process_msg(Req, Struct, Callback)
    end.


process_msg(Req, Struct, Callback) ->
    process_cmd(Req, get_json_map_val(<<"channel">>, Struct), Struct, Callback).


%% WEBSOCKETS COMMANDS    
    
process_ws_cmd(WebSocket, <<"/meta/connect">> = Channel, Struct) ->  
    error_logger:warning_msg("WS CONNECT (~p) ~p ~n",[self(),Struct]),
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),

    %erlfaye_api:replace_connection_ws(ClientId, self(), connected),

    JsonRespFields = if 
            MessageId == undefined -> 
                [{channel,  Channel}, {clientId, ClientId}] ;
            true                   -> 
                [{id, MessageId}, {channel,  Channel}, {clientId, ClientId}]
        end,
    JsonResp  = {struct, [{successful, true} | JsonRespFields]},
    erlfaye_websockets_api:send_data(WebSocket, mochijson2:encode([JsonResp])),
    continue;

process_ws_cmd(WebSocket,<<"/meta/subscribe">> = Channel, Struct) -> 
    error_logger:warning_msg("WS SUBSCRIBE  (~p) channel ~p ~p~n",[self(),Channel, Struct]),    
    JsonResp = process_subscribe(Channel,Struct),
    erlfaye_websockets_api:send_data(WebSocket, mochijson2:encode([JsonResp])),
    continue;

process_ws_cmd(WebSocket, <<"/meta/unsubscribe">> = Channel, Struct) ->   
    error_logger:warning_msg("WS UNSUBSCRIBE (~p) channel ~p ~p~n",[self(), Channel, Struct]),    
    JsonResp = process_unsubscribe(Channel,Struct),
    erlfaye_websockets_api:send_data(WebSocket, mochijson2:encode([JsonResp])),
    continue;

process_ws_cmd(WebSocket, <<"/meta/disconnect">> = Channel, Struct) ->   
    error_logger:warning_msg("WS DISCONNECT (~p) channel ~p ~p~n",[self(), Channel, Struct]),    
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),
    JsonResp = if 
                   MessageId == undefined -> 
                       {struct, [{successful, true},{channel,  Channel}, {clientId, ClientId}]} ;
                   true                   -> 
                       {struct,[{successful, true},{id, MessageId}, {channel,  Channel}, {clientId, ClientId}]}
               end,
    erlfaye_websockets_api:send_data(WebSocket, mochijson2:encode([JsonResp])),
    
    gen_tcp:close(WebSocket),

    % we must stop the websocket loop
    stop;
process_ws_cmd(WebSocket, Channel, Struct) ->  
    error_logger:warning_msg("WS PUBLISH (~p) channel ~p ~p~n",[self(), Channel, Struct]),    
    JsonResp = process_event_channel(Channel,Struct),
    erlfaye_websockets_api:send_data(WebSocket, mochijson2:encode([JsonResp])),
    continue.

%% LONG POLLING COMMANDS    

process_cmd(Req, <<"/meta/handshake">> = Channel, Struct, Callback) ->  
    error_logger:warning_msg("HANDSHAKE: ~p~n",[Struct]),
    %% extract info from the request
    Id = erlfaye_api:generate_id(),
    MessageId = get_json_map_val(<<"id">>, Struct),

    % cache process
    CachePid = spawn(erlfaye_api, cache_loop, [[],0]),
    
    erlfaye_api:replace_connection(Id, 0, CachePid, handshake),
         	
    Advice = {struct, [{reconnect, "retry"},
                       {interval, 2000}]},

    % build response
    JsonRespFields = [{channel, Channel}, 
                      {version, 1.0},
                      {supportedConnectionTypes, [<<"websocket">>, <<"long-polling">>,<<"callback-polling">>]},
                      {clientId, Id},
                      {successful, true},
                      {advice, Advice}],
    JsonResp = if 
                   MessageId == undefined -> 
                       JsonRespFields ;
                   true                   -> 
                       [{id, MessageId} | JsonRespFields]
               end,
    Req:respond({200, [{"ContentType","application/json"}], callback_wrapper(mochijson2:encode([{struct, JsonResp}]), Callback)}),
    done;
    
process_cmd(Req, <<"/meta/connect">> = Channel, Struct, Callback) ->  
    error_logger:warning_msg("CONNECT ~p~n",[Struct]),
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    ConnectionType = get_json_map_val(<<"connectionType">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),
    L = if 
            MessageId == undefined -> 
                [{channel,  Channel}, {clientId, ClientId}] ;
            true                   -> 
                [{id, MessageId}, {channel,  Channel}, {clientId, ClientId}]
        end,

    ReplaceResult = erlfaye_api:replace_connection(ClientId, self(), connected),

    case ReplaceResult of
        {ok, Status} when Status =:= ok ; Status =:= replaced_hs ->
            Connection = erlfaye_api:connection_by_client_pid(self()),
            CachePid = Connection#connection.cache_pid,

            Msg  = {struct, [{successful, true} | L]},
            Resp = Req:respond({200, [], chunked}),
            loop(Resp, #state{id = ClientId, 
                              connection_type = ConnectionType,
                              events = [Msg]},
                CachePid,
                Callback);
            % don't reply immediately to new connect message.
            % instead wait. when new message is received, reply to connect and 
            % include the new message.  This is acceptable given bayeux spec. see section 4.2.2
        {ok, replaced} ->   
            Connection = erlfaye_api:connection_by_client_pid(self()),
            CachePid = Connection#connection.cache_pid,

            Msg  = {struct, [{successful, true} | L]},
            Resp = Req:respond({200, [], chunked}),
            loop(Resp, #state{id = ClientId, 
                              connection_type = ConnectionType,
                              events = [Msg]},
                 CachePid,
                 Callback);
        _ ->
            {struct, [{successful, false} | L]}
    end;    


process_cmd(_Req, <<"/meta/subscribe">> = Channel, Struct, _) ->   
    error_logger:warning_msg("SUBSCRIBE channel ~p ~p~n",[Channel, Struct]),    
    JsonResp = process_subscribe(Channel,Struct),
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    erlfaye_api:deliver_to_connection(ClientId, {struct, JsonResp}),
    done;

process_cmd(_Req, <<"/meta/unsubscribe">> = Channel, Struct, _) ->   
    error_logger:warning_msg("UNSUBSCRIBE channel ~p ~p~n",[Channel, Struct]),    
    JsonResp = process_unsubscribe(Channel,Struct),
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    erlfaye_api:deliver_to_connection(ClientId, {struct, JsonResp}),
    done;

process_cmd(_Req, <<"/meta/disconnect">> = Channel, Struct, _) ->   
    error_logger:warning_msg("UNSUBSCRIBE channel ~p ~p~n",[Channel, Struct]),    
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),

    if 
        MessageId == undefined -> 
            case erlfaye_api:connection_pid(ClientId) of
                undefined -> undefined;
                Pid -> Pid ! stop
            end;
        true                   -> 
            case erlfaye_api:connection_pid(ClientId) of
                undefined -> undefined;
                Pid  -> Pid ! {stop, MessageId}
            end
    end,
    done;

process_cmd(_, Channel, Struct, _) ->  
    error_logger:warning_msg("PUBLISH channel ~p ~p~n",[Channel, Struct]),    
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    JsonResp = process_event_channel(Channel,Struct),
    erlfaye_api:deliver_to_connection(ClientId, {struct, JsonResp}),    

    done.

%% COMMON COMMAND LOGIC

process_subscribe(Channel,Struct) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),
    Subscription = get_json_map_val(<<"subscription">>, Struct),

    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],

    JsonRespFields = case erlfaye_api:subscribe(ClientId, Subscription) of
                         ok ->  [{successful, true}  | L];
                         _ ->  [{successful, false}  | L]
                     end,
    if 
        MessageId == undefined -> 
            JsonRespFields ;
        true                   -> 
            [{id, MessageId} | JsonRespFields]
    end.

process_unsubscribe(Channel,Struct) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),
    Subscription = get_json_map_val(<<"subscription">>, Struct),

    L = [{channel, Channel}, {clientId, ClientId}, {subscription, Subscription}],

    JsonRespFields = case erlfaye_api:unsubscribe(ClientId, Subscription) of
                         ok ->  [{successful, true}  | L];
                         _ ->  [{successful, false}  | L]
                     end,
    if 
        MessageId == undefined -> 
            JsonRespFields ;
        true                   -> 
            [{id, MessageId} | JsonRespFields]
    end.

process_event_channel(Channel,Struct) ->
    ClientId = get_json_map_val(<<"clientId">>, Struct),
    MessageId = get_json_map_val(<<"id">>, Struct),
    Data = get_json_map_val(<<"data">>, Struct),

    L = if 
            MessageId == undefined -> 
                [{channel,  Channel}, {clientId, ClientId}] ;
            true                   -> 
                [{id, MessageId}, {channel,  Channel}, {clientId, ClientId}]
        end,

    case erlfaye_api:deliver_to_channel(Channel, Data) of
        ok -> [{successful, true}  | L];
        _ ->  [{successful, false}  | L]
    end.   

%% UTILS

callback_wrapper(Data, undefined) ->
    Data;       
callback_wrapper(Data, Callback) ->
    lists:concat([Callback, "(", Data, ");"]).

get_json_map_val(Key, {struct, Pairs}) when is_list(Pairs) ->
    case [ V || {K, V} <- Pairs, K =:= Key] of
        [] -> undefined;
        [ V | _Rest ] -> V
    end;
get_json_map_val(_, _) ->
    undefined.

should_continue([]) ->
    true;
should_continue([H|T]) ->
    case H of
        stop ->
            false;
        _  ->
            should_continue(T)
    end.

%%update_cache_pid([],CachePid) ->
%%    CachePid;
%%update_cache_pid([H|T], CachePid) ->
%%    case H of
%%        {continue, Pid} ->
%%            update_cache_pid(T,Pid);
%%        _  ->
%%            update_cache_pid(T, CachePid)
%%    end.
                
