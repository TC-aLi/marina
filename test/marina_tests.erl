-module(marina_tests).
-include("test.hrl").

-compile(export_all).

%% runners
marina_test_() ->
    {setup,
        fun () -> setup([
            {keyspace, <<"test">>}
        ])end,
        fun (_) -> cleanup() end,
    {inparallel, [
        ?T(test_async_execute),
        ?T(test_async_prepare),
        ?T(test_async_query),
        ?T(test_async_reusable_query),
        ?T(test_async_reusable_query_invalid_query),
        ?T(test_counters),
        ?T(test_execute),
        ?T(test_paging),
        ?T(test_query),
        ?T(test_query_metedata_types),
        ?T(test_query_no_metadata),
        ?T(test_reusable_query),
        ?T(test_reusable_query_invalid_query),
        ?T(test_schema_changes),
        ?T(test_timeout_async),
        ?T(test_timeout_sync),
        ?T(test_tuples)
    ]}}.

marina_compression_test_() ->
    {setup,
        fun () -> setup([
            {compression, true},
            {keyspace, <<"test">>}
        ]) end,
        fun (_) -> cleanup() end,
    [?T(test_query)]}.

marina_connection_error_test_() ->
    {setup,
        fun () -> setup([
            {keyspace, <<"test">>},
            {port, 9043}
        ]) end,
        fun (_) -> cleanup() end,
    [?T(test_no_socket)]}.

marina_backlog_test_() ->
    {setup,
        fun () -> setup([
            {backlog_size, 1},
            {keyspace, <<"test">>}
        ]) end,
        fun (_) -> cleanup() end,
    {inparallel, [
        ?T(test_backlogfull_async),
        ?T(test_backlogfull_sync)
    ]}}.

%% tests
test_async_execute() ->
    {ok, StatementId} = marina:prepare(?QUERY1, ?TEST_TIMEOUT),
    {ok, Ref} = marina:async_execute(StatementId, ?CONSISTENCY_ONE, [], self()),
    {ok, _} = marina:receive_response(Ref, ?TEST_TIMEOUT).

test_async_prepare() ->
    {ok, Ref} = marina:async_prepare(?QUERY1, self()),
    {ok, _} = marina:receive_response(Ref, ?TEST_TIMEOUT).

test_async_query() ->
    {ok, Ref} = marina:async_query(?QUERY1, ?CONSISTENCY_ONE, [], self()),
    Response = marina:receive_response(Ref, ?TEST_TIMEOUT),

    ?assertEqual(?QUERY1_RESULT, Response).

test_async_reusable_query() ->
    {ok, Ref} = marina:async_reusable_query(?QUERY3, ?CONSISTENCY_ONE, [], self(), ?TEST_TIMEOUT),
    Response = marina:receive_response(Ref, ?TEST_TIMEOUT),
    {ok, Ref2} = marina:async_reusable_query(?QUERY2, ?QUERY2_VALUES, ?CONSISTENCY_ONE, [], self(), ?TEST_TIMEOUT),
    Response = marina:receive_response(Ref2, ?TEST_TIMEOUT),
    {ok, Ref3} = marina:async_reusable_query(?QUERY2, ?QUERY2_VALUES, ?CONSISTENCY_ONE, [], self(), ?TEST_TIMEOUT),
    Response = marina:receive_response(Ref3, ?TEST_TIMEOUT),

    ?assertEqual(?QUERY1_RESULT, Response).

test_async_reusable_query_invalid_query() ->
    Response = marina:async_reusable_query(<<"SELECT * FROM user LIMIT 1;">>, ?CONSISTENCY_ONE, [], self(), ?TEST_TIMEOUT),

    ?assertEqual({error, {8704, <<"unconfigured columnfamily user">>}}, Response).

test_backlogfull_async() ->
    Responses = [marina:async_query(?QUERY1, ?CONSISTENCY_ONE, [], self()) || _ <- lists:seq(1,100)],
    ?assert(lists:any(fun
        ({error, backlog_full}) -> true;
        (_) -> false
    end, Responses)).

test_backlogfull_sync() ->
    Pid = self(),
    [spawn(fun () ->
        X = marina:query(?QUERY1, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
             Pid ! {response, X}
    end) || _ <- lists:seq(1,20)],

    ?assert(lists:any(fun
        ({error, backlog_full}) -> true;
        (_) -> false
    end, receive_loop(20))).

test_counters() ->
    marina:query(<<"DROP TABLE test.page_view_counts;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"CREATE TABLE test.page_view_counts (counter_value counter, url_name varchar, page_name varchar, PRIMARY KEY (url_name, page_name));">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"UPDATE test.page_view_counts SET counter_value = counter_value + 1 WHERE url_name='adgear.com' AND page_name='home';">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    Response = marina:query(<<"SELECT * FROM test.page_view_counts">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({ok,{result,
        {result_metadata,3,
            [{column_spec,<<"test">>,<<"page_view_counts">>,<<"url_name">>,varchar},
             {column_spec,<<"test">>,<<"page_view_counts">>,<<"page_name">>,varchar},
             {column_spec,<<"test">>,<<"page_view_counts">>,<<"counter_value">>,counter}],
            undefined},
        1,
        [[<<"adgear.com">>,<<"home">>,<<0,0,0,0,0,0,0,1>>]]
    }}, Response).

test_execute() ->
    {ok, StatementId} = marina:prepare(?QUERY1, ?TEST_TIMEOUT),
    Response = marina:execute(StatementId, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual(?QUERY1_RESULT, Response).

test_paging() ->
    marina:query(<<"INSERT INTO test.users (key, column1, column2, value) values (99492dfe-d94a-11e4-af39-58f44110757e, 'test', 'test2', intAsBlob(0));">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    Query = <<"SELECT * FROM users LIMIT 10;">>,
    {ok,{result,Metadata,1,Rows}} = marina:query(Query, ?CONSISTENCY_ONE, [{page_size, 1}], ?TEST_TIMEOUT),
    {result_metadata,4,_,PagingState} = Metadata,

    {ok,{result,Metadata2,1,Rows2}} = marina:query(Query, ?CONSISTENCY_ONE, [{page_size, 1}, {paging_state, PagingState}], ?TEST_TIMEOUT),
    {result_metadata,4,_,PagingState2} = Metadata2,

    ?assertNotEqual(PagingState, PagingState2),
    ?assertNotEqual(Rows, Rows2).

test_query() ->
    Response = marina:query(?QUERY1, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual(?QUERY1_RESULT, Response).

test_query_metedata_types() ->
    marina:query(<<"DROP TABLE entries;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    Columns = datatypes_columns(?DATA_TYPES),
    Query = <<"CREATE TABLE entries(",  Columns/binary, " PRIMARY KEY(col1));">>,
    Response = marina:query(Query, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({ok,{<<"CREATED">>,<<"TABLE">>,{<<"test">>,<<"entries">>}}}, Response),

    Values = [
        <<"hello">>,
        marina_types:encode_long(100000),
        <<"blob">>,
        marina_types:encode_boolean(true)
    ] ,
    Response2 = marina:query(<<"INSERT INTO entries (col1, col2, col3, col4) VALUES (?, ?, ?, ?)">>, Values, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({ok, undefined}, Response2),

    Response3 = marina:query(<<"SELECT * FROM entries LIMIT 1;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({ok,{result,
        {result_metadata,17,
            [{column_spec,<<"test">>,<<"entries">>,<<"col1">>,ascii},
             {column_spec,<<"test">>,<<"entries">>,<<"col10">>,uid},
             {column_spec,<<"test">>,<<"entries">>,<<"col11">>,varchar},
             {column_spec,<<"test">>,<<"entries">>,<<"col12">>,varint},
             {column_spec,<<"test">>,<<"entries">>,<<"col13">>,timeuuid},
             {column_spec,<<"test">>,<<"entries">>,<<"col14">>,inet},
             {column_spec,<<"test">>,<<"entries">>,<<"col15">>,{list,varchar}},
             {column_spec,<<"test">>,<<"entries">>,<<"col16">>,{map,varchar,varchar}},
             {column_spec,<<"test">>,<<"entries">>,<<"col17">>,{set,varchar}},
             {column_spec,<<"test">>,<<"entries">>,<<"col2">>,bigint},
             {column_spec,<<"test">>,<<"entries">>,<<"col3">>,blob},
             {column_spec,<<"test">>,<<"entries">>,<<"col4">>,boolean},
             {column_spec,<<"test">>,<<"entries">>,<<"col5">>,decimal},
             {column_spec,<<"test">>,<<"entries">>,<<"col6">>,double},
             {column_spec,<<"test">>,<<"entries">>,<<"col7">>,float},
             {column_spec,<<"test">>,<<"entries">>,<<"col8">>,int},
             {column_spec,<<"test">>,<<"entries">>,<<"col9">>,timestamp}],
            undefined},
        1,
        [[<<"hello">>,null,null,null,null,null,null,null,null,<<0,0,0,0,0,1,134,160>>,<<"blob">>,<<1>>,null,null,null,null,null]]
    }}, Response3).

test_query_no_metadata() ->
    Response2 = marina:query(?QUERY1, ?CONSISTENCY_ONE, [{skip_metadata, true}], ?TEST_TIMEOUT),

    ?assertEqual({ok,{result,
    {result_metadata, 4, [], undefined}, 1, [
        [<<153,73,45,254,217,74,17,228,175,57,88,244,65,16,117,125>>, <<"test">>, <<"test2">>, <<0,0,0,0>>]
    ]}}, Response2).

test_no_socket() ->
    Response = marina:query(?QUERY1, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({error, no_socket}, Response).

test_reusable_query() ->
    Response = marina:reusable_query(?QUERY1, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    Response = marina:reusable_query(?QUERY1, [], ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    Response = marina:reusable_query(?QUERY2, ?QUERY2_VALUES, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual(?QUERY1_RESULT, Response).

test_reusable_query_invalid_query() ->
    Response = marina:reusable_query(<<"SELECT * FROM user LIMIT 1;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({error, {8704, <<"unconfigured columnfamily user">>}}, Response).

test_schema_changes() ->
    marina:query(<<"DROP KEYSPACE test2;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"CREATE KEYSPACE test2 WITH REPLICATION = {'class':'SimpleStrategy', 'replication_factor':1};">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"CREATE TYPE test2.address (street text, city text, zip_code int, phones set<text>);">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"CREATE TABLE test2.users (key uuid, column1 text, column2 frozen<test2.address>, value blob, PRIMARY KEY (key, column1, column2));">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    Response = marina:query(<<"SELECT * FROM test2.users LIMIT 1;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({ok,{result,
    {result_metadata,4,
        [{column_spec,<<"test2">>,<<"users">>,<<"key">>,uid},
         {column_spec,<<"test2">>,<<"users">>,<<"column1">>,varchar},
         {column_spec,<<"test2">>,<<"users">>,<<"column2">>,
             {udt,<<"test2">>,<<"address">>,
                 [{<<"street">>,varchar},
                  {<<"city">>,varchar},
                  {<<"zip_code">>,int},
                  {<<"phones">>,{set,varchar}}]}},
         {column_spec,<<"test2">>,<<"users">>,<<"value">>,blob}], undefined},
    0,[]}}, Response),

    marina:query(<<"DROP TABLE test2.users;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"DROP KEYSPACE test2;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT).

test_timeout_async() ->
    {ok, Ref} = marina:async_query(?QUERY1, ?CONSISTENCY_ONE, [], self()),
    Response = marina:receive_response(Ref, 0),

    ?assertEqual({error, timeout}, Response).

test_timeout_sync() ->
    Response = marina:query(?QUERY1, ?CONSISTENCY_ONE, [], 0),

    ?assertEqual({error, timeout}, Response).

test_tuples() ->
    marina:query(<<"CREATE TABLE collect_things (k int PRIMARY KEY, v frozen <tuple<int, text, float>>);">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    Response = marina:query(<<"SELECT * FROM test.collect_things;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),

    ?assertEqual({ok,{result,
        {result_metadata,2,
            [{column_spec,<<"test">>,<<"collect_things">>,<<"k">>,int},
             {column_spec,<<"test">>,<<"collect_things">>,<<"v">>,
                 {tuple,[int,varchar,float]}}],
            undefined},
    0,[]}}, Response),

    marina:query(<<"DROP TABLE collect_things;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT).

%% utils
boostrap() ->
    marina:query(<<"DROP KEYSPACE test;">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"CREATE KEYSPACE test WITH REPLICATION = {'class':'SimpleStrategy', 'replication_factor':1};">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"CREATE TABLE test.users (key uuid, column1 text, column2 text, value blob, PRIMARY KEY (key, column1, column2));">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT),
    marina:query(<<"INSERT INTO test.users (key, column1, column2, value) values (99492dfe-d94a-11e4-af39-58f44110757d, 'test', 'test2', intAsBlob(0))">>, ?CONSISTENCY_ONE, [], ?TEST_TIMEOUT).

cleanup() ->
    error_logger:tty(false),
    application:stop(marina),
    error_logger:tty(true).

datatypes_columns(Cols) ->
    list_to_binary(datatypes_columns(1, Cols)).

datatypes_columns(_I, []) ->
    [];
datatypes_columns(I, [ColumnType|Rest]) ->
    Column = io_lib:format("col~B ~s, ", [I, ColumnType]),
    [Column | datatypes_columns(I+1, Rest)].

receive_loop(0) -> [];
receive_loop(N) ->
    receive
        {response, X} ->
            [X | receive_loop(N - 1)]
    end.

setup(EnvironmentVars) ->
    error_logger:tty(false),
    application:stop(marina),

    marina_app:start(),
    boostrap(),
    application:stop(marina),

    application:load(marina),
    [application:set_env(?APP, K, V) || {K, V} <- EnvironmentVars],
    marina_app:start(),

    error_logger:tty(true).

test(Test) ->
    {atom_to_list(Test), ?MODULE, Test}.
