%% -------------------------------------------------------------------
%%
%% riak_btree_backend: storage engine based on CouchDB B+ Tree
%%
%% Copyright (c) 2011 Trifork A/S  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc riak_btree_backend is a Riak storage backend using btree.

-module(riak_btree_backend).
-author('Kresten Krab Thorup <krab@trifork.com>').

-behavior(riak_kv_backend).
-behavior(gen_server).

-include("couch_db.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% riak_kv_backend exports
-export([start/2,stop/1,get/2,put/3,list/1,list_bucket/2,fold_bucket_keys/4,
         delete/2,fold/3, is_empty/1, drop/1, callback/3]).

%% api to compactor
-export([finish_compact/1]).

%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

% @type state() = term().
-record(state, {btree, path, compactor, config}).

-define(COMPACTION_CHECK_INTERVAL, timer:minutes(60)).

% @spec start(Partition :: integer(), Config :: proplist()) ->
%                        {ok, state()} | {{error, Reason :: term()}, state()}
start(Partition, Config) ->
    %% make sure the app is started
    ok = start_app(),

    PID = gen_server:start_link(?MODULE, [Partition, Config], []),

    Ref = make_ref(),
    erlang:put(Ref,PID),
    schedule_compaction(Ref),
    maybe_schedule_sync(Ref),
    PID.


init([Partition, Config]) ->
    ConfigRoot = get_opt(data_root, Config),
    if ConfigRoot =:= undefined ->
            riak:stop("riak_btree_backend::data_root unset, failing.~n");
       true -> ok
    end,

    TablePath = filename:join([ConfigRoot, integer_to_list(Partition)]),
    case filelib:ensure_dir(TablePath) of
        ok -> ok;
        _Error ->
            riak:stop("riak_btree_backend could not ensure"
                      " the existence of its root directory")
    end,

    BtreeName = list_to_atom(integer_to_list(Partition)),
    BtreeFileName = filename:join(TablePath, BtreeName),

    initstate(BtreeFileName, Config).

initstate(BtreeFileName, Config) ->
    case couch_file:open(BtreeFileName, [sys_db]) of

        {ok, Fd} -> %% open existing file
            {ok, #db_header{local_docs_btree_state = HeaderBtree}} =
                couch_file:read_header(Fd),
            {ok, Bt} = couch_btree:open(HeaderBtree, Fd, []),
            {ok, #state{ btree=Bt, path=BtreeFileName, config=Config }};

        {error, enoent} ->
            %% if we crashed during swapping a .compact file, then
            %% we have a .save file to use
            case couch_file:open(BtreeFileName ++ ".save", [sys_db]) of

                {ok, Fd} -> %% open existing file
                    file:rename(BtreeFileName ++ ".save", BtreeFileName),
                    {ok, #db_header{local_docs_btree_state = HeaderBtree}} =
                        couch_file:read_header(Fd),
                    {ok, Bt} = couch_btree:open(HeaderBtree, Fd, []),
                    {ok, #state{ btree=Bt, path=BtreeFileName, config=Config }};

                {error, enoent} ->
                    case couch_file:open(BtreeFileName, [create,sys_db]) of
                        {ok, Fd} ->
                            Header = #db_header{},
                            ok = couch_file:write_header(Fd, Header),
                            {ok, Bt} = couch_btree:open(nil, Fd, []),
                            {ok, #state{ btree=Bt, path=BtreeFileName, config=Config }};

                        {error, _} = Error ->
                            Error;
                        Error ->
                            {error, Error}
                    end;

                {error, _} = Error ->
                    Error;
                Error ->
                    {error, Error}
            end
    end
.

get_opt(Key, #state{config=Config}) ->
    get_opt(Key, Config);
get_opt(Key, Opts) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(?MODULE, Key) of
                {ok, Value} -> Value;
                undefined -> undefined
            end;
        Value ->
            Value
    end.

start_app() ->
    case application:start(?MODULE) of
        ok ->
            ok;
        {error, {already_started, ?MODULE}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.


%% @private
handle_cast({finish_compact, CompactorPID}, State) ->
    srv_finish_compact(State, CompactorPID);
handle_cast(sync, #state{btree=#btree{fd=Fd}}=State) ->
    couch_file:sync(Fd),
    {noreply, State};
handle_cast(compaction_check, #state{btree=Bt,path=Path}=State) ->
    case State#state.compactor =:= undefined of
        true ->
            CompactorPID = riak_btree_backend_compactor:start(self(), Bt, Path),
            State#state{compactor=CompactorPID};
        false ->
            {noreply, State}
    end;
handle_cast(_, State) -> {noreply, State}.

%% @private
handle_call(get_btree,_From,State) ->
    {reply, State#state.btree, State};
handle_call(stop,_From,State) ->
    {reply, srv_stop(State), State};
handle_call({put,BKey,Val},_From,State) ->
    srv_put(State,BKey,Val);
handle_call({delete,BKey},_From,State) ->
    srv_delete(State,BKey);
handle_call(drop, _From, State) ->
    srv_drop(State).

get_btree(SrvRef) ->
    gen_server:call(SrvRef,get_btree).

commit_data(Bt, Bt, State) -> State;
commit_data(#btree{fd = Fd}, Bt2, State) ->
    ok = couch_file:write_header(Fd,
				 #db_header{local_docs_btree_state =
						couch_btree:get_state(Bt2)}),
    case get_opt(sync_strategy, State) of
        o_sync ->
            couch_file:sync(Fd);
        _ ->
            ok
    end,
    State.


%% must be called from compactor
finish_compact(SrvRef) ->
    gen_server:cast(SrvRef, {finish_compact, self()}).

srv_finish_compact(#state{compactor=CompactorPID, btree=#btree{fd=FdIn}, path=Path}=State,
                   {finish_compact, CompactorPID}) ->

    ok = couch_file:sync(FdIn),
    ok = couch_file:close(FdIn),
    ok = file:rename(Path, Path ++ ".save"),

    try riak_btree_backend_compactor:complete_compaction(CompactorPID, Path) of
        {ok, BTree} ->
            {noreply, State#state{compactor=undefined, btree=BTree}}
    catch
        Class:Reason ->
            error_logger:error_msg("compaction swap failed with ~p:~p", [Class,Reason]),
            ok = file:rename(Path ++ ".save", Path),
            {noreply, initstate(Path, State#state.config)}
    end.


% @spec stop(state()) -> ok | {error, Reason :: term()}
stop(SrvRef) ->
    gen_server:call(SrvRef, stop).
srv_stop(#state{btree=#btree{fd=Fd}}) ->
    couch_file:close(Fd).

% get(state(), riak_object:bkey()) ->
%   {ok, Val :: binary()} | {error, Reason :: term()}
% key must be 160b
get(SrvRef,BKey) ->
    Bt = get_btree(SrvRef),
    Key = sext:encode(BKey),
    case couch_btree:lookup(Bt, [Key]) of
        [not_found] ->
            {error, notfound};
        [{ok, {_Key, Found}}] ->
            {ok, Found}
    end.

% put(state(), riak_object:bkey(), Val :: binary()) ->
%   ok | {error, Reason :: term()}
% key must be 160b
put(SrvRef,BKey,Val) ->
    gen_server:call(SrvRef, {put, BKey,Val}).
srv_put(#state{btree=Bt,compactor=CompactorPID}=State,BKey,Val) ->
    Key = sext:encode(BKey),
    {ok, Bt2} = couch_btree:add_remove(Bt, [{Key, Val}], [Key]),
    State2 = commit_data(Bt, Bt2, State),
    case CompactorPID of
        undefined  -> ok;
        _ ->
            gen_server:cast(CompactorPID, {did_put, Key, Val, Bt2})
    end,
    {reply, ok, State2#state{btree=Bt2}}.

% delete(state(), riak_object:bkey()) ->
%   ok | {error, Reason :: term()}
% key must be 160b
delete(SrvRef,BKey) ->
    gen_server:call(SrvRef, {delete, BKey}).
srv_delete(#state{btree=Bt,compactor=CompactorPID}=State, BKey) ->
    Key = sext:encode(BKey),
    {ok, Bt2} = couch_btree:add_remove(Bt, [], [Key]),
    State2 = commit_data(Bt, Bt2,State),
    case CompactorPID of
        undefined  -> ok;
        _ ->
            gen_server:cast(CompactorPID, {did_delete, Key, Bt2})
    end,
    {reply, ok, State2#state{btree=Bt2}}.

% list(state()) -> [riak_object:bkey()]
list(SrvRef) ->
    fold(SrvRef,
         fun(BK, _V, Acc) ->
                 [BK | Acc]
         end,
         []).

list_bucket(SrvRef, {filter, Bucket, Fun0}) ->
    Bt = get_btree(SrvRef),
    Prefix = sext:prefix({Bucket, '_'}),
    Fun = fun({BinKey,_Value},Acc) ->
                  case sext:decode(BinKey) of
                      {Bucket, K} ->
                          case Fun0(K) of
                              true  -> {ok, [K|Acc]};
                              false -> {ok, Acc}
                          end;

                      {_, _} ->
                          {stop, Acc}
                  end
          end,
    {ok, _, Acc2} = couch_btree:fold(Bt, Fun, [], [{start_key, Prefix}]),
    Acc2;

list_bucket(SrvRef, '_') ->
    Bt = get_btree(SrvRef),
    loop_list_buckets(Bt, sext:prefix({'_','_'}), []);

list_bucket(SrvRef, Bucket) ->
    Bt = get_btree(SrvRef),
    Prefix = sext:prefix({Bucket, '_'}),
    Fun = fun({BinKey,_Value},Acc) ->
                  case sext:decode(BinKey) of
                      {Bucket, K} ->
                          {ok, [K|Acc]};
                      {_, _} ->
                          {stop, Acc}
                  end
          end,
    {ok, _, Acc2} = couch_btree:fold(Bt, Fun, [], [{start_key, Prefix}]),
    Acc2.

loop_list_buckets(Bt, From, List) ->
    Fun = fun({BinKey,_Value}, notfound) ->
                  {Bucket,_Key} = sext:decode(BinKey),
                  {stop, Bucket}
          end,

    case couch_btree:fold(Bt, Fun, notfound, [{start_key, From}]) of
        {ok, _, notfound} ->
            List;
        {ok, _, Bucket} ->
            NextFrom = sext:prefix({<<Bucket/binary,0>>,'_'}),
            loop_list_buckets(Bt,NextFrom,[Bucket|List])
    end.

fold_bucket_keys(SrvRef, Bucket, Fun0, Acc0) ->
    Bt = get_btree(SrvRef),
    Prefix = sext:prefix({Bucket, '_'}),
    Fun = fun({BinKey,_Value},Acc) ->
                  case sext:decode(BinKey) of
                      {Bucket, K} ->
                          {ok, Fun0(K,Acc)};
                      {_, _} ->
                          {stop, Acc}
                  end
          end,
    {ok, _, Acc2} = couch_btree:fold(Bt, Fun, Acc0, [{start_key, Prefix}]),
    Acc2.

fold(SrvRef,Fun0,Acc0) ->
    Bt = get_btree(SrvRef),
    Fun = fun({BinKey,V},Acc) ->
                  BK = sext:decode(BinKey),
                  {ok, Fun0(BK, V, Acc)}
          end,
    {ok, _, Acc2} = couch_btree:fold(Bt, Fun, Acc0, []),
    Acc2.

is_empty(SrvRef) ->
    try fold(SrvRef,
             fun(_, _, _) -> throw(not_empty) end,
             empty)
    of
        empty ->
            true
    catch
        _:not_empty ->
            false
    end.

drop(SrvRef) ->
    gen_server:call(SrvRef, drop).
srv_drop(#state{btree=#btree{fd=Fd}, path=P}) ->
    ok = couch_file:close(Fd),
    ok = file:delete(P),
    {reply, ok, #state{}}.

callback({Ref, _}, Ref, {sync, SyncInterval}) when is_reference(Ref) ->
    case erlang:get(Ref) of
        SrvRef when is_pid(SrvRef) ->
            gen_server:cast(Ref, sync)
    end,
    schedule_sync(Ref, SyncInterval);
callback({Ref, _}, Ref, compaction_check) when is_reference(Ref) ->
    case erlang:get(Ref) of
        SrvRef when is_pid(SrvRef) ->
            gen_server:cast(Ref, compaction_check)
    end,
    schedule_compaction(Ref);
%% Ignore callbacks for other backends so multi backend works
callback(_State, _Ref, _Msg) ->
    ok.

%% @private
handle_info(_Msg, State) -> {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) -> {ok, State}.


%% @private
%% Schedule sync (if necessary)
maybe_schedule_sync(Ref) when is_reference(Ref) ->
    case application:get_env(riak_btree_backend, sync_strategy) of
        {ok, {seconds, Seconds}} ->
            SyncIntervalMs = timer:seconds(Seconds),
            schedule_sync(Ref, SyncIntervalMs);
        {ok, none} ->
            ok;
        BadStrategy ->
            error_logger:info_msg("Ignoring invalid bitcask sync strategy: ~p\n",
                                  [BadStrategy]),
            ok
    end.

schedule_sync(Ref, SyncIntervalMs) when is_reference(Ref) ->
    riak_kv_backend:callback_after(SyncIntervalMs, Ref, {sync, SyncIntervalMs}).

schedule_compaction(Ref) when is_reference(Ref) ->
    riak_kv_backend:callback_after(?COMPACTION_CHECK_INTERVAL, Ref, compaction_check).




-ifdef(TEST).
%%
%% Test
%%

simple_test() ->
    ?assertCmd("rm -rf test/btree-backend"),
    Config = [{data_root, "test/btree-backend"}],
    riak_kv_backend:standard_test(?MODULE, Config).

list_bucket_test() ->
    ?assertCmd("rm -rf test/btree-backend"),
    Config = [{data_root, "test/btree-backend"}],

    {ok, S} = ?MODULE:start(42, Config),
    ok = ?MODULE:put(S, {<<"b1">>,<<"k1">>}, <<"v1">>),
    ok = ?MODULE:put(S, {<<"b1">>,<<"k2">>}, <<"v1">>),
    ok = ?MODULE:put(S, {<<"b11">>,<<"k1">>}, <<"v1">>),
    ok = ?MODULE:put(S, {<<"b11">>,<<"k2">>}, <<"v1">>),
    ok = ?MODULE:put(S, {<<"b2">>,<<"k1">>}, <<"v2">>),
    [<<"b1">>,<<"b11">>,<<"b2">>] = lists:sort(list_bucket(S,'_')),
    [<<"k1">>,<<"k2">>] = lists:sort(list_bucket(S,<<"b11">>)).


-ifdef(EQC).

eqc_test_() ->
    {timeout, 60,
     [{"eqc test", ?_test(eqc_test_inner())}]}.

eqc_test_inner() ->
    Cleanup =
        fun(State, OldS) ->
                case State of
                    #state{} ->
                        drop(State);
                    _ ->
                        ok
                end,
                [file:delete(S#state.path) || S <- OldS]
        end,
    Config = [{data_root, "test/btree-backend"}],
    ?assertCmd("rm -rf test/btree-backend"),
    ?assertEqual(true, backend_eqc:test(?MODULE, false, Config, Cleanup)).
-endif. % EQC
-endif. % TEST
