%%%----------------------------------------------------------------------
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 3 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(rtpproxy_ctl).
-author('lemenkov@gmail.com').

-export([start/0]).
-export([stop/0]).
-export([save_config/1]).
-export([command/1]).

-include("common.hrl").

start() ->
	%% Replace logger with erlsyslog and remove default tty handler
	error_logger:tty(false),
	error_logger:add_report_handler(erlsyslog),

	%% Load necessary config files
	application:load(rtpproxy),

	%% Load main module
	application:start(rtpproxy).

stop() ->
	%% Stop erlrtpproxy gracefully
	rtpproxy_ctl:command(#cmd{type = ?CMD_X, timestamp = os:timestamp()}),
	%% Stop main node
	init:stop().

save_config(ConfigPath) ->
	{ok,[Config]} = file:consult(ConfigPath),
	NewConfig = proplists:delete(rtpproxy, Config) ++ [{rtpproxy, application:get_all_env(rtpproxy)}],
	file:write_file(ConfigPath, io_lib:format("~p.~n", [NewConfig])).

% Simply stop all active sessions
command(#cmd{type = ?CMD_X}) ->
	[supervisor:terminate_child(media_sup, SID) || {SID,_,_,_} <- supervisor:which_children(media_sup)],
	ok;

command(#cmd{type = ?CMD_D, callid = C}) ->
	SIDs = [SID || {SID = {media_channel_sup, CID, _},_,_,_} <- supervisor:which_children(media_sup), CID == C],
	case SIDs of
		[] -> {error, notfound};
		_ -> lists:foreach(fun(X) -> supervisor:terminate_child(media_sup, X) end, SIDs)
	end;

% DEPRECATED. Use HTTP-JSON.
command(#cmd{type = ?CMD_I}) ->
	{ok, {stats, length(supervisor:which_children(media_sup))}};

command(#cmd{type = ?CMD_U, callid = C, mediaid = M, from = #party{tag = T, addr = {{0,0,0,0}, _}}, origin = #origin{pid = Pid}} = Cmd) ->
	% Old music-on-hold - FIXME - should start CMD_P actually
	[SupervisorPid] = [ P || {{media_channel_sup, CID, MID}, P, _, _} <- supervisor:which_children(media_sup), CID == C, MID == M],
	RtpPid = get_gen_rtp_channel(SupervisorPid, C, M, T),
	{_, {_, RtpPort, RtcpPort}, _} = gen_server:call(RtpPid, get_phy),
	backend_ser:reply(Cmd, {{{0,0,0,0}, RtpPort}, {{0,0,0,0}, RtcpPort}}),
	{ok, sent};

command(#cmd{type = ?CMD_U, callid = C, mediaid = M, from = #party{tag = T}, params = Params, origin = #origin{pid = Pid}} = Cmd) ->
	SupRet = supervisor:start_child(media_sup,
		{
			{media_channel_sup, C, M},
			{supervisor, start_link, [rtpproxy_sup, media_channel_sup]},
			temporary,
			5000,
			supervisor,
			[rtpproxy_sup]
		}
	),

	% Determine IP...
	Ip = case {proplists:get_value(local, Params), proplists:get_value(remote, Params), proplists:get_value(ipv6, Params)} of
		{_, _, true} ->
			{ok, I} = application:get_env(rtpproxy, ipv6), I;
		{undefined, _, _} ->
			{ok, I} = application:get_env(rtpproxy, external), I;
		{{_,_,_,_}, undefined, _} ->
			{ok, I} = application:get_env(rtpproxy, internal), I
	end,

	{SupervisorPid, Port} = case SupRet of
		{ok, P} ->
%			random:seed(os:timestamp()),
%			RP = 2*(512+random:uniform(32767-512)),
%			spawn(backend_ser, reply, [Cmd, {{Ip, RP}, {Ip, RP+1}}]),
%			{P, RP};
			{P, 0};
		{error, {already_started, P}} ->
			{P, 0}
	end,

	% Check if we need to start recording
	proplists:get_value(copy, Params, false) andalso start_recorder(SupervisorPid, C, M, T),

	% Start RTP handler
	spawn(
		fun() ->
			% Determine options...
			{ok, TimeoutEarly} = application:get_env(rtpproxy, ttl_early),
			{ok, Timeout} = application:get_env(rtpproxy, ttl),
			{ok, SendRecvStrategy} = application:get_env(rtpproxy, sendrecv),
			{ok, ActiveStrategy} = application:get_env(rtpproxy, active),
			Params1 = Params ++ [{port, Port}, {ip, Ip}, {timeout_early, TimeoutEarly*1000}, {timeout, Timeout*1000}, {sendrecv, SendRecvStrategy}, {active, ActiveStrategy}],

			% ..and start RTP socket module
			Ret0 = supervisor:start_child(SupervisorPid,
				{{phy, C, M, T}, {gen_server, start_link, [gen_rtp_channel, [Params1], []]}, permanent, 5000, worker, [gen_rtp_channel]}
			),
			RtpPid0 = get_pid(Ret0),
			{_, {Ip, RtpPort, RtcpPort}, _} = gen_server:call(RtpPid0, get_phy),
%			gen_server:cast(RtpPid, {update, Params ++ [{sendrecv, SendRecvStrategy}]}),
%			gen_server:cast(RtpPid, {update, [{sendrecv, SendRecvStrategy}, {prefill, {Ip, Addr}}]}),
			Port == 0 andalso spawn(backend_ser, reply, [Cmd, {{Ip, RtpPort}, {Ip, RtcpPort}}]),
			ok
		end
	),

	% Check and load (if configured) notification backends
	case application:get_env(rtpproxy, radacct_servers) of
		{ok, _} -> supervisor:start_child(
				SupervisorPid,
				{{notify_radius, C, M}, {gen_server, start_link, [rtpproxy_notifier_backend_radius, [C, M], []]}, temporary, 5000, worker, [rtpproxy_notifier_backend_radius]}
			);
		_ -> ok
	end,
	case application:get_env(rtpproxy, notify_servers) of
		{ok, NotifyType} ->
			NotifyInfo = proplists:get_value(notify, Params, []),
			((NotifyInfo == []) and (NotifyType == tcp)) orelse supervisor:start_child(
				SupervisorPid,
				{{notify_openser, C, M}, {gen_server, start_link, [rtpproxy_notifier_backend_notify, [NotifyInfo], []]}, temporary, 5000, worker, [rtpproxy_notifier_backend_notify]}
			);
		_ -> ok
	end,
	{ok, sent};

command(#cmd{type = ?CMD_L, callid = C, mediaid = M, from = #party{tag = T}, params = Params, origin = #origin{pid = Pid}} = Cmd) ->
	case [ P || {{media_channel_sup, CID, MID}, P, _, _} <- supervisor:which_children(media_sup), CID == C, MID == M] of
		[SupervisorPid] ->
			% Determine IP...
			Ip = case {proplists:get_value(local, Params), proplists:get_value(remote, Params), proplists:get_value(ipv6, Params)} of
				{_, _, true} ->
					{ok, I} = application:get_env(rtpproxy, ipv6), I;
				{undefined, _, _} ->
					{ok, I} = application:get_env(rtpproxy, external), I;
				{{_,_,_,_}, undefined, _} ->
					{ok, I} = application:get_env(rtpproxy, internal), I
			end,

			Port = 0,

			% Check if we need to start recording
			proplists:get_value(copy, Params, false) andalso start_recorder(SupervisorPid, C, M, T),

			% Start RTP handler
			spawn(
				fun() ->
					% Determine options...
					{ok, TimeoutEarly} = application:get_env(rtpproxy, ttl_early),
					{ok, Timeout} = application:get_env(rtpproxy, ttl),
					{ok, SendRecvStrategy} = application:get_env(rtpproxy, sendrecv),
					{ok, ActiveStrategy} = application:get_env(rtpproxy, active),
					Params1 = Params ++ [{port, Port}, {ip, Ip}, {timeout_early, TimeoutEarly*1000}, {timeout, Timeout*1000}, {sendrecv, SendRecvStrategy}, {active, ActiveStrategy}],

					% ..and start RTP socket module
					Ret0 = supervisor:start_child(SupervisorPid,
						{{phy, C, M, T}, {gen_server, start_link, [gen_rtp_channel, [Params1], []]}, permanent, 5000, worker, [gen_rtp_channel]}
					),
					RtpPid0 = get_pid(Ret0),
					{_, {Ip, RtpPort, RtcpPort}, _} = gen_server:call(RtpPid0, get_phy),
		%			gen_server:cast(RtpPid, {update, Params ++ [{sendrecv, SendRecvStrategy}]}),
		%			gen_server:cast(RtpPid, {update, [{sendrecv, SendRecvStrategy}, {prefill, {Ip, Addr}}]}),
					Port == 0 andalso spawn(backend_ser, reply, [Cmd, {{Ip, RtpPort}, {Ip, RtcpPort}}]),

					% Set RTP path
					RtpPid1 = get_other_gen_rtp_channel(SupervisorPid, C, M, T),
					safe_call(RtpPid0, {rtp_subscriber, {set, RtpPid1}}),
					safe_call(RtpPid1, {rtp_subscriber, {set, RtpPid0}}),
					ok
				end
			);
		_ ->
			spawn(backend_ser, reply, [Cmd, {error, notfound}])
	end,
	{ok, sent};

command(#cmd{type = ?CMD_P, callid = C, mediaid = M, to = #party{tag = T}, params = Params}) ->
	[SupervisorPid] = [ P || {{media_channel_sup, CID, MID}, P, _, _} <- supervisor:which_children(media_sup), CID == C, MID == M],
	RtpPid0 = get_gen_rtp_channel(SupervisorPid, C, M, T),
	RtpPid1 = get_other_gen_rtp_channel(SupervisorPid, C, M, T),
	Ret = supervisor:start_child(SupervisorPid,
		% FIXME we should ignore payload type sent by OpenSIPS/B2BUA and append one currently in use
		{{player, C, M, T}, {gen_server, start_link, [player, [RtpPid0, proplists:get_value(codecs, Params, {'PCMU',8000,1}), binary_to_list(proplists:get_value(filename, Params, <<"default">>)), proplists:get_value(playcount, Params, 0)], []]}, temporary, 5000, worker, [player]}
	),
	gen_server:cast(RtpPid0, {keepalive, disable}),
	gen_server:cast(RtpPid1, {keepalive, disable}),
	safe_call(RtpPid0, {rtp_subscriber, {set, null}}),
	safe_call(RtpPid1, {rtp_subscriber, {set, null}}),
	ok;

command(#cmd{type = ?CMD_S, callid = C, mediaid = M, to = #party{tag = T}}) ->
	[SupervisorPid] = [ P || {{media_channel_sup, CID, MID}, P, _, _} <- supervisor:which_children(media_sup), CID == C, MID == M],
	RtpPid0 = get_gen_rtp_channel(SupervisorPid, C, M, T),
	RtpPid1 = get_other_gen_rtp_channel(SupervisorPid, C, M, T),
	gen_server:cast(RtpPid0, {keepalive, enable}),
	gen_server:cast(RtpPid1, {keepalive, enable}),
	safe_call(RtpPid0, {rtp_subscriber, {set, RtpPid1}}),
	safe_call(RtpPid1, {rtp_subscriber, {set, RtpPid0}}),
	supervisor:terminate_child(SupervisorPid, {player, C, M, T}),
	ok;

command(#cmd{type = ?CMD_R, callid = C}) ->
	SupervisorPids = [ P || {{media_channel_sup, CID, _}, P, _, _} <- supervisor:which_children(media_sup), CID == C],
	[ start_recorder(SupervisorPid,CID,MID,TID) || SupervisorPid <- SupervisorPids, {{media, CID, MID, TID}, _, _, _} <- supervisor:which_children(SupervisorPid)],
	ok;

command(_) ->
	% FIXME CMD_C and CMD_Q not yet supported
	ok.

%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions %%
%%%%%%%%%%%%%%%%%%%%%%%%

start_recorder(SupervisorPid, C, M, T) ->
	Ret = supervisor:start_child(SupervisorPid,
			{{recorder, C, M, T}, {gen_server, start_link, [file_writer, [C, M, T], []]}, temporary, 5000, worker, [file_writer]}
		),
	RecorderPid = get_pid(Ret),
	RtpPid = get_gen_rtp_channel(SupervisorPid, C, M, T),
	safe_call(RtpPid, {rtp_subscriber, {set, RecorderPid}}),
	ok.

get_gen_rtp_channel(SupervisorPid, C, M, T) ->
	case [ P || {{phy, CID, MID, TID}, P, _, _} <- supervisor:which_children(SupervisorPid), CID == C, MID == M, TID == T] of
		[] -> null;
		[RtpPid] -> RtpPid
	end.

get_other_gen_rtp_channel(SupervisorPid, C, M, T) ->
	case [ P || {{phy, CID, MID, TID}, P, _, _} <- supervisor:which_children(SupervisorPid), CID == C, MID == M, TID /= T] of
		[] -> null;
		[RtpPid] -> RtpPid;
		% 18x/200 from a different direction
		% FIXME we should stop this pair and restart it again
		[RtpPid | _] -> RtpPid
	end.

get_pid({ok, Pid}) -> Pid;
get_pid({ok, Pid, _}) -> Pid;
get_pid({error, {already_started, Pid}}) -> Pid.

safe_call(null, _Message) -> ok;
safe_call(Pid, Message) -> gen_server:call(Pid, Message).
