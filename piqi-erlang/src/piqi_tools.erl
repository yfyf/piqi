%% Copyright 2009, 2010, 2011 Anton Lavrik
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%
%% @doc Erlang bindings for Piqi tools
%%
%% This module contains Erlang binding for some of Piqi tools functions such as
%% "piqi convert". It is implemented as a gen_server that communicates with Piqi
%% tools server ("piqi server") via Erlang port interface.
%%
-module(piqi_tools).

-behavior(gen_server).


% TODO: tests, edoc


-export([start_link/0]).
% API
-export([add_piqi/1, convert/5, convert/6, ping/0]).
% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
% entry point of the port receiver process
-export([port_receiver/2]).


-include("piqirun.hrl").
-include("piqi_tools.hrl").

% type definitions generated by piqic
-include("piqi_rpc_piqi.hrl").


%-define(DEBUG, 1).
-ifdef(DEBUG).
-include("debug.hrl").
-endif.


% gen_server:call timeout
-define(CALL_TIMEOUT, 5000).


% Options for "piqi server" port command
-ifdef(DEBUG).
-define(PIQI_FLAGS, "").
-else.
-define(PIQI_FLAGS, " --no-warnings"). % XXX: --trace
-endif.


-define(PIQI_TOOLS_ERROR, 'piqi_tools_error').

-define(PORT_START_TIMEOUT, 2000). % 2 seconds


% state of the port sender process (piqi_tools gen_server)
-record(sender_state, {
    % Erlang port id
    port :: port()
}).


% state of the port receiver process
-record(receiver_state, {
    % Erlang port id
    port :: port(),

    % Pid of the parent process
    parent :: pid()
}).


%
% starting gen_server
%

start_link() ->
    gen_server:start_link(?MODULE, [], []).


%
% gen_server callbacks
%

%% @private
init([]) ->
    Command = piqi:get_command("piqi") ++ " server" ++ ?PIQI_FLAGS,
    %Command = "tee ilog | piqi server --trace | tee olog",

	case filelib:is_file( piqi:get_command("piqi")) of
		false ->
			{stop, {cant_find_piqi_executable, Command}};
		true ->
			Port = start_port_receiver(Command),
			State = #sender_state{ port = Port },
			{ok, State}
	end.


%% @private
handle_call({rpc, PiqiMod, Request}, From, State = #sender_state{port = Port}) ->
    rpc_call(PiqiMod, Request, From, Port),
    {noreply, State}.


%% @private
handle_cast(Info, State) ->
    StopReason = {?PIQI_TOOLS_ERROR, {'unexpected_cast', Info}},
    {stop, StopReason, State}.


handle_info(Info, State) ->
    StopReason = {?PIQI_TOOLS_ERROR, {'unexpected_info', Info}},
    {stop, StopReason, State}.


%% @private
terminate(_Reason, _State = #sender_state{port = Port}) ->
    % don't bother checking if the port is still valid, e.g. after EXIT
    catch erlang:port_close(Port),
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


% start a new port receiver process
start_port_receiver(Command) ->
    _Pid = spawn_link(?MODULE, port_receiver, [self(), Command]),
    receive
        {'started', Port} -> Port
    after ?PORT_START_TIMEOUT ->
        exit({?PIQI_TOOLS_ERROR, 'open_port_timeout'})
    end.


% entry point of the process responsible for receiving RPC responses from the
% erlang Port
port_receiver(Parent, Command) ->
    erlang:process_flag(trap_exit, true),

    % TODO: handle initialization error and report it as {error, Error} tuple
    % TODO, XXX: on error, sleep for a while to prevent an immediate restart
    % attempt
    % XXX: use {spawn_executable, Command} instead to avoid shell's error
    % messages printed on stderr?

    % XXX: what about closing the port?
    %erlang:port_close(State#receiver_state.port),

    Port = erlang:open_port({spawn, Command}, [{packet, 4}, binary]), % exit_status?
    Parent ! {'started', Port},

    State = #receiver_state{ port = Port, parent = Parent },
    port_receive_loop(State).


port_receive_loop(State = #receiver_state{port = Port, parent = Parent}) ->
    receive
        Message ->
            case Message of
                {Port, {data, Packet}} ->
                    NewState = handle_rpc_response(Packet, State),
                    port_receive_loop(NewState);
                {'EXIT', Port, Reason} ->
                    StopReason = {?PIQI_TOOLS_ERROR, {'port_command_exited', Reason}},
                    exit(StopReason);
                {'EXIT', Parent, _Reason} ->
                    exit(normal);
                _ ->
                    StopReason = {?PIQI_TOOLS_ERROR, {'unexpected_message', Message}},
                    exit(StopReason)
            end
    end.


% do the actual rpc call
rpc_call(PiqiMod, Request, From, Port) ->
    % NOTE: using process dictionary as a fast SET container to check whether
    % type information from this module has been added to the piqi server
    % XXX: use 'sets' module's sets instead of process dictionary?
    case PiqiMod =:= 'undefined' orelse get(PiqiMod) =:= 'add_piqi' of
        false ->
            % add type information to the Piqi server from the module before
            % calling the actual server function

            % XXX: check if the function is exported?
            BinPiqiList = PiqiMod:piqi(),

            % memorize that we've added type information for this module (well,
            % we haven't but it is better than implementing some kind of
            % blocking for subsequent rpc calls while this request is
            % executing). If there's any problem with add_piqi, the gen_server
            % will crash when it receives unsuccessful response form the Port.
            erlang:put(PiqiMod, 'add_piqi'),

            % add type information from the PiqiMod to the Piqi-tools server
            send_add_piqi_request(Port, BinPiqiList);
        true ->
            % type information is either not required or has been added already
            % => just make the rpc call
            ok
    end,
    CallerRef = term_to_binary(From),
    send_rpc_request(Port, CallerRef, Request).


% send "add_piqi" request directry to the port
send_add_piqi_request(Port, BinPiqiList) ->
    BinInput = encode_add_piqi_input(BinPiqiList),

    % the response will be handled by handle_rpc_response() -- see below
    CallerRef0 = <<"add-piqi">>, % custom caller reference
    Request0 = encode_rpc_request(<<"add-piqi">>, BinInput),
    send_rpc_request(Port, CallerRef0, Request0).


handle_rpc_response(Packet, State) ->
    {Caller, Payload} = parse_rpc_packet(Packet),

    % send response to the client or handle "add_piqi_local" response
    % NOTE: "add_piqi_local" was called implicitly by the server itself
    case Caller of
        <<"add-piqi">> ->
            Response = piqi_rpc_piqi:parse_response(Payload),
            case decode_add_piqi_output(Response) of
                ok -> ok;
                X ->
                    Reason = {?PIQI_TOOLS_ERROR, {'unexpected_add_piqi_response', X}},
                    exit(Reason)
            end;
        <<>> ->
            Response = piqi_rpc_piqi:parse_response(Payload),
            Reason = {?PIQI_TOOLS_ERROR, {'no_caller_ref_in_response', Response}},
            % XXX: continue instead of exiting?
            exit(Reason);
        _ ->
            Client = binary_to_term(Caller),
            gen_server:reply(Client, Payload)
    end,
    State.


%
% Piqi-RPC request/response
%

% @hidden send a Piqi-RPC request
% NOTE: responses will be handled by a separate port_receiver() process
send_rpc_request(Port, CallerRef, Request) ->
    send_rpc_packet(Port, CallerRef, Request).


% @hidden send a Piqi-RPC packet
send_rpc_packet(Port, CallerRef, Payload) ->
    CallerRefSize = size(CallerRef),
    Command = [<<CallerRefSize:16>>, CallerRef, Payload],
    % NOTE: this is a blocking call. If the port is busy, the process will be
    % suspended until the port becomes available.
    true = erlang:port_command(Port, Command).


parse_rpc_packet(Packet) ->
    try
        <<CallerRefSize:16, Rest/binary>> = Packet,
        % return a tuple of two binaries: {CallerRef, Payload}
        split_binary(Rest, CallerRefSize)
    catch
        _:_ ->
            Reason = {?PIQI_TOOLS_ERROR, {'received_invalid_rpc_packet', Packet}},
            exit(Reason)
    end.


%
% API implementation
%

-spec rpc/3 :: (
    PiqiMod :: 'undefined' | atom(),
    Name :: binary() | string(),
    ArgsData :: 'undefined' | iodata() ) -> piqi_rpc_response().

% make an RPC call for function name "Name" and Protobuf-encoded arguments
% "ArgsData". "PiqiMod" is the name of the Erlang module that was generated by
% "piqic erlang". This module must contain type information for the function
% arguments.
%
rpc(PiqiMod, Name, ArgsData) ->
    BinData =
        case ArgsData of
            'undefined' -> 'undefined';
            _ -> iolist_to_binary(ArgsData)
        end,
    Request = encode_rpc_request(Name, BinData),
    ResponseBin = call_server({rpc, PiqiMod, Request}),
    piqi_rpc_piqi:parse_response(ResponseBin).


encode_rpc_request(FuncName, ArgsData) ->
    Request = #piqi_rpc_request{ name = FuncName, data = ArgsData },
    RequestIolist = piqi_rpc_piqi:gen_request(Request),
    % make sure that we send binary to the server to avoid implicit term
    % serialization/deserialization
    iolist_to_binary(RequestIolist).


-spec rpc/2 :: (
    Name :: binary() | string(),
    ArgsData :: 'undefined' | iodata() ) -> piqi_rpc_response().

% make an RPC call of function "Name" and Protobuf-encoded arguments
% "ArgsData"
rpc(Name, ArgsData) ->
    rpc(_PiqiMod = 'undefined', Name, ArgsData).


-spec rpc/1 :: ( Name :: binary() | string() ) -> piqi_rpc_response().

% make an RPC call of function "Name" that doesn't have input parameters
rpc(Name) ->
    rpc(Name, _ArgsData = 'undefined').


% XXX: use timeout?
call_server(Args) ->
    % XXX: High-availability setup, allowing the gen_server to restart quickly
    % without failing the calls. This might be useful for "piqi server" upgrades
    % and in case of potential "piqi server" crashes.
    try
        Pid = piqi_sup:pick_piqi_server(),
        gen_server:call(Pid, Args, ?CALL_TIMEOUT)
    catch
        % Piqi tools has exited, but hasn't been restarted by Piqi supervisor
        % yet
        exit:{noproc, _} ->
            Pid1 = piqi_sup:force_pick_piqi_server(),
            gen_server:call(Pid1, Args, ?CALL_TIMEOUT)
    end.


-spec ping/0 :: () -> ok.

% a simple service livecheck function
ping() ->
    rpc(<<"ping">>).


-spec add_piqi/1 :: (BinPiqiList :: [binary()]) -> ok | {error, string()}.

% add a Protobuf-encoded Piqi module specifications to Piqi tools. Added types
% will be used later by "convert" and other functions.
add_piqi(BinPiqiList) ->
    BinInput = encode_add_piqi_input(BinPiqiList),
    % send request to the gen_server
    Output = rpc(<<"add-piqi">>, BinInput),
    decode_add_piqi_output(Output).


encode_add_piqi_input(BinPiqiList) ->
    Input = #piqi_tools_add_piqi_input{
        format = 'pb',
        data = BinPiqiList
    },
    BinInput = piqi_tools_piqi:gen_add_piqi_input(Input),
    iolist_to_binary(BinInput).


decode_add_piqi_output(Output) ->
    case Output of
        ok -> ok;
        {error, BinError} ->
            Error = piqi_tools_piqi:parse_add_piqi_error(BinError),
            % NOTE: parsed strings are represented as binaries
            {error, binary_to_list(Error)};
        X ->
            handle_common_result(X)
    end.


-spec convert/6 :: (
    PiqiMod :: 'undefined' | atom(), % Erlang module generated by "piqic erlang"
    TypeName :: string() | binary(),
    InputFormat :: piqi_convert_input_format(),
    OutputFormat :: piqi_convert_output_format(),
    Data :: binary(),
    Options :: piqi_convert_options()) -> {ok, Data :: binary()} | {error, string()}.

% convert `Data` of type `TypeName` from `InputFormat` to `OutputFormat`
convert(PiqiMod, TypeName, InputFormat, OutputFormat, Data, Options) ->
    Input = #piqi_tools_convert_input{
        type_name = TypeName,
        input_format = InputFormat,
        output_format = OutputFormat,
        data = Data,
        pretty_print = proplists:get_value('pretty_print', Options),
        json_omit_null_fields = proplists:get_value('json_omit_null_fields', Options),
        use_strict_parsing = proplists:get_value('use_strict_parsing', Options)
    },
    BinInput = piqi_tools_piqi:gen_convert_input(Input),
    case rpc(PiqiMod, <<"convert">>, BinInput) of
        {ok, BinOutput} ->
            Output = piqi_tools_piqi:parse_convert_output(BinOutput),
            Res = Output#piqi_tools_convert_output.data,
            {ok, Res};
        {error, BinError} ->
            Error = piqi_tools_piqi:parse_convert_error(BinError),
            % NOTE: parsed strings are represented as binaries
            {error, binary_to_list(Error)};
        X ->
            handle_common_result(X)
    end.


-spec convert/5 :: (
    PiqiMod :: 'undefined' | atom(), % Erlang module generated by "piqic erlang"
    TypeName :: string() | binary(),
    InputFormat :: piqi_tools_format(),
    OutputFormat :: piqi_tools_format(),
    Data :: binary() ) -> {ok, Data :: binary()} | {error, string()}.

% convert `Data` of type `TypeName` from `InputFormat` to `OutputFormat`
convert(PiqiMod, TypeName, InputFormat, OutputFormat, Data) ->
    convert(PiqiMod, TypeName, InputFormat, OutputFormat, Data, _Options = []).


handle_common_result({rpc_error, _} = X) ->
    % recoverable protocol-level error
    throw({?PIQI_TOOLS_ERROR, X}).

