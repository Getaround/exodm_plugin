%% @doc API functions for Exosense server plugin development
%%
%% This module contains support functions for Exosense server (exodm) plugins.
%%
%% @end
-module(exodm_plugin).

-export([add_http_session/0,
	 login/2, login/3,
	 logout/0, logout/1,
	 get_account/0]).

-export([notification/4,
	 queue_notification/4,
	 queue_reverse_request/4,
	 check_queue/2]).

-export([get_cached_config/3]).

-export([device_exists/1,
	 lookup_device_position/1,
	 lookup_device_keys/1,
	 lookup_device_attr/2,
	 add_device_session/2,
	 remove_device_session/2]).

-include_lib("lager/include/log.hrl").

-type account   () :: binary().
-type user      () :: binary().
-type device_id () :: binary().
-type config_set() :: binary().
-type protocol  () :: binary().
-type latitude  () :: float().
-type longitude () :: float().
-type timestamp () :: integer().
-type position  () :: {latitude(), longitude(), timestamp()}.
-type key       () :: binary().
-type client_key() :: key().
-type server_key() :: key().
-type key_pair  () :: {client_key(), server_key()}.

-spec add_http_session() -> ok.
%% @doc Activate a Yaws server instance for the current application.
%%
%% When a plugin application is reloaded/activated, this function can be called
%% to load (or reload) a HTTP server instance, as specified in the application
%% environment `{yaws_sconf, SConf}', where `SConf' is a server configuration
%% list as described in [http://yaws.hyber.org/embed.yaws].
%% The setting is read and expanded using
%% {@link //setup/setup:get_env/2. setup:get_env/2}, which means that e.g.
%% the "variables" `$PRIV_DIR', `$LIB_DIR', `$HOME', etc. can be used.
%% @end
add_http_session() ->
    exodm_http:add_session().

-spec login(account(), user()) -> boolean().
%% @equiv login(Account, User, true)
login(Account, User) ->
    login(Account, User, true).

-spec login(account(), user(), boolean()) -> boolean().
%% @doc Authorize the current process as a given account and user.
%%
%% As a rule, it is good to log in as the user `<Account>-admin', as it is
%% created automatically when the account is, and thus is guaranteed to exist.
%%
%% If `Subscribe' is `true', subscription on account deletion events is
%% initiated. If an account is deleted, the current process will receive a
%% message `{exodm_db_account, delete, AnyAccount}' (note: not just for the
%% current account). This allows the process to stop performing operations
%% that rely on the presence of `Account'.
%% @end
login(Account, User, Subscribe) ->
    login_(Account, User, Subscribe, 3).

-spec logout() -> ok.
%% @equiv logout(true)
logout() ->
    logout(true).

-spec logout(boolean()) -> ok.
%% @doc Log out the current process.
%%
%% If `Resubscribe' is true, this call will activate a subscription on account
%% add events. I.e. if an account is added/deleted, the current process will
%% receive messages of the form `{exodm_db_account, add, AcctName}'
%% (note: not just for the wanted account). This allows processes to be 
%% started before the actual account has been created, and then automatically
%% pick up the account creation event and log in.
%% @end
logout(Resubscribe) when is_boolean(Resubscribe) ->
    exodm_db_session:logout(),
    exodm_db_account:unsubscribe(delete),
    if Resubscribe ->
	    catch
		exodm_db_account:subscribe(add);  % crashes if called repeatedly
       true ->
	    ok
    end,
    ok.

-spec get_account() -> account().
%% @doc Retrieves the current authorized account of the current process.
%%
%% This function will raise an exception if the current process is not
%% authorized (see {@link login/2}).
%% @end
get_account() ->
    exodm_db_session:get_aid().

-spec get_cached_config(config_set(), integer(), device_id()) ->
			       {ok, kvdb_conf:conf_tree()} | {error, any()}.

%% @doc Retrieves a cached config data set.
%%
%% This function is used in response to a `push-config-set' RPC.
%% When config set data is pushed, it is first stored in a cache, with a
%% reference for every affected device. Afterwards, a `push-config-set' RPC
%% is sent to each device. The data is in the form of a `kvdb_conf' config
%% config tree (see {@link //kvdb/kvdb_conf. kvdb_conf}).
%% @end
get_cached_config(ConfigSet, Ref, DeviceID) ->
    AID = exodm_db_session:get_aid(),
    exodm_db_config:get_cached(AID, ConfigSet, Ref, DeviceID).

-spec device_exists(device_id()) -> boolean().
%% @doc Check if the given device exists.
%%
%% Returns `true' if the device exists, `false' otherwise.
%% @end
device_exists(DID) ->
    exodm_db_device:exist(exodm_db_session:get_aid(), DID).

-spec lookup_device_position(device_id()) -> position().
%% @doc Lookup the last known position of the device.
%%
%% If no position is stored, `{0.0, 0.0, 0}' is returned.
%% @end
lookup_device_position(DeviceID) ->
    exodm_db_device:lookup_position(get_account(), DeviceID).

-spec lookup_device_keys(device_id()) -> key_pair().
%% @doc Lookup the key pair associated with device.
%%
%% If no keypair exists, `{<<0,0,0,0,0,0,0,0>>, <<0,0,0,0,0,0,0,0>>}'
%% is returned.
%% @end
lookup_device_keys(DeviceID) ->
    exodm_db_device:lookup_keys(get_account(), DeviceID).

-spec lookup_device_attr(_Attr::binary(), device_id()) -> [{_Attr, any()}] | [].
%% @doc Lookup an attribute value in a device object.
%%
%% If the device doesn't exist, or the requested attribute is not stored,
%% the empty list (`[]') is returned.
%% @end
lookup_device_attr(Attr, DeviceID) ->
    exodm_db_device:lookup_attr(get_account(), DeviceID, Attr).

-spec add_device_session(protocol(), device_id()) -> true.
%% @doc Register an active device session with a given protocol.
%%
%% Device sessions indicate that the device is on-line and ready to send
%% and receive requests and notifications. Specifically, the current
%% process registers a {@link //gproc/gproc:reg/1. gproc property},
%% `{p, l, {exodm_rpc, active_device, ExtID, Protocol}}', which
%% may be good to know while debugging. `ExtID' is an external representation
%% of the account name and device ID.
%% @end
add_device_session(Protocol, DeviceID) ->
    ?debug("add_device_session(~p, ~p)~n", [DeviceID, Protocol]),
    exodm_rpc_handler:add_device_session(get_account(), DeviceID, Protocol).

-spec remove_device_session(device_id(), protocol()) -> true.
%% @doc Remove an active device session.
%%
%% This function removes a device session registered via
%% {@link add_device_session/2}. It will always succeed, even if there is no
%% such session.
%% @end
remove_device_session(DeviceID, Protocol) ->
    ?debug("remove_device_session(~p, ~p)~n", [DeviceID, Protocol]),
    exodm_rpc_handler:rm_device_session(get_account(), DeviceID, Protocol).

check_queue(Direction, DeviceID0) when Direction==to_device;
				       Direction==from_device ->
    DeviceID = exodm_db:encode_id(DeviceID0),
    ?debug("check_queue(~p, ~p)~n", [Direction, DeviceID]),
    ExtID = exodm_db:enc_ext_key(get_account(), DeviceID),
    exodm_rpc_dispatcher:check_queue(Direction, ExtID).

notification(Method, Elems, Env, DeviceID) ->
    ?debug("notification(~p, ~p, ~p, ~p)~n", [Method, Elems, Env, DeviceID]),
    AID = get_account(),
    case exodm_db_device:exist(AID, DeviceID) of
	true ->
	    exodm_rpc_handler:notification(Method, Elems, Env, AID, DeviceID);
	false ->
	    ?debug("no such device (~p, ~p)~n", [AID, DeviceID]),
	    error(unknown_device)
    end.

queue_notification(Module, Method, Elems, Env) when is_list(Elems),
						    is_list(Env) ->
    ?debug("(~p, ~p, ~p, ~p)~n", [Module, Method, Elems, Env]),
    exodm_rpc:queue_notification(Module, notify, Env, Method, Elems).

queue_reverse_request(Module, Method, Elems, Env) ->
    exodm_rpc:queue_notification(Module, reverse_request, Env, Method, Elems).

login_(Account, User, Subscribe, Retries) when is_integer(Retries) ->
    case get_account_id(Account) of
	AID when is_binary(AID) ->
	    case exodm_db_session:set_auth_as_user(
		   AID, User, kvdb_conf, _Sticky=true) of
		false when Retries > 0 ->
		    timer:sleep(500),
		    login_(Account, User, Subscribe, Retries-1);
		false ->
		    false;
		true ->
		    exodm_db_session:set_trusted_proc(),
		    if Subscribe ->
			    exodm_db_account:unsubscribe(add),
			    catch exodm_db_account:subscribe(delete),
			    true;
		       true ->
			    true
		    end
	    end;
	false ->
	    false
    end.

get_account_id(Acct) ->
    case exodm_db_account:exist(Acct) of
	false ->
	    case exodm_db_account:lookup_by_name(Acct) of
		AID when is_binary(AID) ->
		    AID;
		false ->
		    false
	    end;
	true ->
	    Acct
    end.