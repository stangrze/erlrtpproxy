-module(rtpproxy_radius).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-include_lib("eradius/include/eradius_lib.hrl").
-include_lib("eradius/include/dictionary.hrl").
-include_lib("eradius/include/dictionary_cisco.hrl").

start_link(Args) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init(_) ->
	{ok, RadAcctServers} = application:get_env(?MODULE, radacct_servers),
	eradius_dict:start(),
	eradius_dict:load_tables(["dictionary", "dictionary_cisco"]),
	eradius_acc:start(),
	{ok, #rad_accreq{servers=RadAcctServers}}.

handle_call(_Message, _From , State) ->
	{reply, {error, unknown_call}, State}.

handle_cast(Other, State) ->
	CallID = "test",

	Req0 = State#rad_accreq{
		login_time = erlang:now(),
		std_attrs=[{?Acct_Session_Id, CallID}],
		vend_attrs = [{?Cisco, [{?h323_connect_time, date_time_fmt()}]}]
	},
	eradius_acc:acc_start(Req0),

	eradius_acc:acc_update(Req0),

	Req1 = eradius_acc:set_logout_time(Req0),
	Req2 = Req1#rad_accreq{
		vend_attrs = [{?Cisco, [{?h323_disconnect_time, date_time_fmt()}]}]
	},
	eradius_acc:acc_stop(Req2),

	{noreply, State}.

handle_info(Other, State) ->
	{noreply, State}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

terminate(Reason, State) ->
	ok.

%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions %%
%%%%%%%%%%%%%%%%%%%%%%%%

date_time_fmt() ->
	{{YYYY,MM,DD},{Hour,Min,Sec}} = erlang:localtime(),
	% DayNumber = calendar:day_of_the_week({YYYY,MM,DD}),
	% lists:flatten(io_lib:format("~s ~3s ~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w ~4.4.0w",[httpd_util:day(DayNumber),httpd_util:month(MM),DD,Hour,Min,Sec,YYYY])).
	lists:flatten(io_lib:format("~4.4.0w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w", [YYYY, MM, DD, Hour,Min,Sec])).