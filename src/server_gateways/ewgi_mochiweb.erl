%%%----------------------------------------------------------------------
%% @copyright Hunter Morris
%% @author Hunter Morris <huntermorris@gmail.com>
%% @version {@vsn}, {@date}, {@time}
%% @doc ewgi MochiWeb server gateway
%%
%% See LICENSE file in this source package
%%%----------------------------------------------------------------------

-module(ewgi_mochiweb).

%% ewgi callbacks
-export([req/2, rsp/3]).

-include("ewgi.hrl").

-spec req(MochiReq::tuple(), Opts::list()) -> #ewgi_req{}.
    
req(MochiReq, Opts) ->
    R = ewgi:new_req(),
    Folder = fun(F, Req) -> F(MochiReq, Opts, Req) end,
    lists:foldl(Folder, R, [fun method/3,
                            fun script_name/3,
                            fun path/3,
                            fun url_scheme/3,
                            fun server_pair/3,
                            fun peer_pair/3,
                            fun headers/3,
                            fun input/3,
                            fun errors/3]).

-spec rsp(MochiReq::tuple(), Opts::list(), Rsp::#ewgi_rsp{}) -> 'ok' | {'error', any()}.

rsp(MochiReq, _Opts, Rsp) when is_record(Rsp, ewgi_rsp) ->
    {Code, _Msg} = ewgi:status(Rsp),
    Headers = ewgi:rsp_headers(Rsp),
    case ewgi:body(Rsp) of
        F when is_function(F, 0) ->
            % Stream returned, so chunk response
            % XXX: This should only be allowed for HTTP/1.1 requests
            rsp_stream(F, MochiReq:respond({Code, Headers, chunked}));
        Iol ->
            MochiReq:respond({Code, Headers, Iol})
    end.

rsp_stream(F, Rsp) when is_function(F, 0) ->
    case F() of
        {H, T} when is_function(T, 0), H =/= <<>>, H =/= [] ->
            Rsp:write_chunk(H),
            rsp_stream(T, Rsp);
        {} ->
            Rsp:write_chunk([])
    end.

method(MochiReq, _Opts, R0) ->
    Method = MochiReq:get(method),
    ewgi:method(Method, R0).

script_name(_MochiReq, Opts, R0) ->
    Script = proplists:get_value(script, Opts, []),
    ewgi:script_name(Script, R0).

path(MochiReq, _Opts, R0) ->
    RawPath = MochiReq:get(raw_path),
    path_fold(RawPath, R0).

path_fold('*', R0) ->
    R = ewgi:path_info("*", R0),
    ewgi:query_string([], R);
path_fold(Raw, R0) ->
    {Path, Query, _Frag} = mochiweb_util:urlsplit_path(Raw),
    R = ewgi:path_info(Path, R0),
    ewgi:query_string(Query, R).

url_scheme(_MochiReq, _Opts, R) ->
    % This defaults to http at the moment, but support for https would
    % have to be passed through from MochiWeb somehow.
    ewgi:url_scheme("http", R).

server_pair(MochiReq, _Opts, R0) ->
    {Name, Port} = ewgi_util:socket_server_pair(MochiReq:get(socket)),
    R = ewgi:server_port(Port, R0),
    ewgi:server_name(Name, R).

peer_pair(MochiReq, _Opts, R0) ->
    {Name, Port} = ewgi_util:socket_peer_pair(MochiReq:get(socket)),
    R = ewgi:server_port(Port, R0),
    ewgi:server_name(Name, R).

headers(MochiReq, _Opts, R0) ->
    MochiHdrs = MochiReq:get(headers),
    L = mochiweb_headers:to_list(MochiHdrs),
    lists:foldl(fun({K0, V}, Req) ->
                        K = header_key_to_list(K0),
                        ewgi:add_req_header(K, V, Req)
                end, R0, L).

header_key_to_list(L) when is_list(L) ->
    L;
header_key_to_list(A) when is_atom(A) ->
    atom_to_list(A);
header_key_to_list(B) when is_binary(B) ->
    binary_to_list(B).

input(MochiReq, _Opts, R0) ->
    F = fun(Callback, Length) ->
                input1(MochiReq, Callback, Length)
        end,
    ewgi:input(F, R0).

input1(Req, Callback, Length) ->
    case Req:get_header_value("expect") of
        "100-continue" ->
            Req:start_raw_response({100, gb_trees:empty()});
        _Else ->
            ok
    end,
    read_input(Req, Callback, Length).

%% No chunk size specified, so use default 1024 byte chunks
read_input(Req, Callback, Length) when is_integer(Length) ->
    read_input(Req, Callback, {Length, 1024});

%% Final callback after entire input has been read
read_input(_Req, Callback, {Length, _ChunkSz})
  when is_function(Callback, 1), Length =< 0 ->
    Callback(eof);

%% Continue reading and calling back with each chunk of data
read_input(Req, Callback, {Length, ChunkSz})
  when is_function(Callback, 1) ->
    Bin = recv_input(Req, Length, ChunkSz),
    Rem = Length - size(Bin),
    NewCallback = Callback({data, Bin}),
    read_input(Req, NewCallback, {Rem, ChunkSz}).

%% Read either Length bytes or ChunkSz, whichever is smaller
recv_input(Req, Length, ChunkSz) when Length > 0, Length < ChunkSz ->
    Req:recv(Length);
recv_input(Req, _Length, ChunkSz) ->
    Req:recv(ChunkSz).

errors(_MochiReq, _Opts, R0) ->
    ewgi:errors(fun error_logger:error_report/1, R0).
