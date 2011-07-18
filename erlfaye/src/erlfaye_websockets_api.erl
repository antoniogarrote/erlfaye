-module(erlfaye_websockets_api).
-author('antoniogarrote@gmail.com').
-include("erlycomet.hrl").
-include_lib("stdlib/include/qlc.hrl").

%% @see
%%
%% http://erlang.2086793.n4.nabble.com/about-websocket-76-in-erlang-td3347563.html
%% https://github.com/davebryson/erlang_websocket/blob/master/src/websocket_request.erl
%%
%% @author Dave Bryson [http://weblog.miceda.org]
%% @author zhangbo
%%

%% API
-export([is_upgrade_request/1,
        try_to_upgrade/1,
        get_data/1,
        send_data/2,
        unframe/1]).


-define(WEBSOCKET_PREFIX,"HTTP/1.1 101 Web Socket Protocol Handshake\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\n").


is_upgrade_request(MochiwebRequest) ->
    Headers = MochiwebRequest:get(headers),
    case mochiweb_headers:get_value('Upgrade',Headers) of
        "WebSocket" ->
            true;
        _Other ->
            false
    end.


try_to_upgrade(MochiwebRequest) ->
    Socket = MochiwebRequest:get(socket),
    Headers = MochiwebRequest:get(headers),
    Path = MochiwebRequest:get(path),
    Body = MochiwebRequest:recv(8),
    inet:setopts(Socket, [{keepalive, true},{packet, raw},{active,true}]),

    case mochiweb_headers:get_value('Upgrade',Headers) of
        "WebSocket" ->
            send_handshake(Socket,Path,Headers,Body),
            Socket;
        _Other ->
            gen_tcp:close(Socket),
            false
    end.

send_handshake(Socket,Path,Headers,Body) ->
    Origin = mochiweb_headers:get_value("Origin",Headers),
    Location = mochiweb_headers:get_value('Host',Headers),

    Sec1 = mochiweb_headers:get_value('Sec-Websocket-Key1',Headers),
    Sec2 = mochiweb_headers:get_value('Sec-Websocket-Key2',Headers),
    %% -example from wikipedia:
    %% Sec1 = "4 @1  46546xW%0l 1 5",
    %% Sec2 = "12998 5 Y3 1  .P00",
    %% Body = <<"^n:ds[4U">>,
    %% -Result:
    %% 8jKS'y:G*Co,Wxa-

    {Skey1 ,Skey2} = process_keys(Sec1,Sec2),
    ComputedHandshake = binary_to_list(erlang:md5(<<Skey1:32/big-unsigned-integer, Skey2:32/big-unsigned-integer, Body/binary>>)),

    Resp = ?WEBSOCKET_PREFIX ++
        "Sec-WebSocket-Location: ws://" ++ Location ++ Path ++ "\r\n" ++
        "Sec-WebSocket-Origin: " ++ Origin ++ "\r\n\r\n"++
        ComputedHandshake,
    gen_tcp:send(Socket, Resp),
    done.    


get_data(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok,Data} ->
            unframe(binary_to_list(Data), [], []);
        _Other ->
            undefined
    end.


send_data(Socket,Data) ->
    gen_tcp:send(Socket, [0] ++ Data ++ [255]).

unframe(Data) ->
    unframe(Data,[],[]).
unframe([0|T],_Current, Acum) -> unframe1(T,[],Acum).
unframe1([255],Current,Acum) -> lists:reverse([lists:reverse(Current)|Acum]);
unframe1([255|T],Current,Acum) -> unframe(T,[],[lists:reverse(Current)|Acum]);
unframe1([H|T],Current,Acum) ->
    unframe1(T,[H|Current],Acum).

% Process the keys as mentioned in the handshake 76 draft of the ietf. 
process_keys(Key1, Key2)-> 
    {Digits1, []} = string:to_integer(digits(Key1)),
    {Digits2, []} = string:to_integer(digits(Key2)), 
    Spaces1 = spaces(Key1), 
    Spaces2 = spaces(Key2), 
    {Digits1 div Spaces1, Digits2 div Spaces2}. 

% Concatenate digits 0-9 of a string 
digits(X)-> [A || A<-X, A =< 57, A >= 48]. 

% Count number of spaces in a string. 
spaces(X)-> string:len([ A || A<-X, A =:= 32]). 
