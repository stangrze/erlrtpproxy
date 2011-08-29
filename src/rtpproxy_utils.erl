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

-module(rtpproxy_utils).
-author('lemenkov@gmail.com').

-include("../include/common.hrl").

-export([get_fd_pair/1]).
-export([get_ipaddrs/2]).
-export([is_rfc1918/1]).

%% Determine the list of suitable IP addresses
get_ipaddrs(_IsRfc1918, _IsIpv6) ->
	% TODO IPv4 only and external
	{ok, IPv4List} = inet:getif(),
	FilterIP = fun (F) ->
			fun
				({[], X}) ->
					X;
				% Loopback
				({[{{127, _, _, _}, _Bcast,_Mask} | Rest], X}) ->
					F({Rest, X});
				% RFC 1918, 10.0.0.0 - 10.255.255.255
				({[{{10, _, _, _}, _Bcast,_Mask} | Rest], X}) ->
					F({Rest, X});
				% RFC 1918, 172.16.0.0 - 172.31.255.255
				({[{{172, A, _, _}, _Bcast,_Mask} | Rest], X}) when A > 15, A < 32 ->
					F({Rest, X});
				% RFC 1918, 192.168.0.0 - 192.168.255.255
				({[{{192, 168, _, _}, _Bcast,_Mask} | Rest], X}) ->
					F({Rest, X});
				({[ {IPv4, _Bcast, _Mask} | Rest], X}) ->
					F({Rest, X ++ [IPv4]})
			end
	end,
	[MainIp | _Rest ] = (y:y(FilterIP))({IPv4List, []}),
	MainIp.

%% Open a pair of UDP ports - N and N+1 (for RTP and RTCP consequently)
get_fd_pair({Direction, IsIpv6}) ->
	Ip  = rtpproxy_utils:get_ipaddrs(Direction, IsIpv6),
	get_fd_pair(Ip, 10).
get_fd_pair(Ip, 0) ->
	?ERR("Create new socket at ~p FAILED", [Ip]),
	error;
get_fd_pair(Ip, NTry) ->
	case gen_udp:open(0, [binary, {ip, Ip}, {active, once}, {raw,1,11,<<1:32/native>>}]) of
		{ok, Fd} ->
			{ok, {Ip,Port}} = inet:sockname(Fd),
			Port2 = case Port rem 2 of
				0 -> Port + 1;
				1 -> Port - 1
			end,
			case gen_udp:open(Port2, [binary, {ip, Ip}, {active, once}, {raw,1,11,<<1:32/native>>}]) of
				{ok, Fd2} ->
					if
						Port > Port2 -> {Fd2, Fd};
						Port < Port2 -> {Fd, Fd2}
					end;
				{error, _} ->
					gen_udp:close(Fd),
					get_fd_pair(Ip, NTry - 1)
			end;
		{error, _} ->
			get_fd_pair(Ip, NTry - 1)
	end.

% TODO only IPv4 for now
is_rfc1918({I0,I1,I2,I3} = Ip) when	is_integer(I0), I0 > 0, I0 < 256,
					is_integer(I1), I1 >= 0, I1 < 256,
					is_integer(I2), I2 >= 0, I2 < 256,
					is_integer(I3), I3 >= 0, I3 < 256
				->
	is_rfc1918_guarded(Ip);
is_rfc1918(Ip) ->
	?ERR("BAD IPv4 addr ~p", [Ip]),
	throw({error, "Not a valid IPv4 address"}).

% Loopback (actually, it's not a RFC1918 network)
is_rfc1918_guarded({127,_,_,_}) ->
	true;
% RFC 1918, 10.0.0.0 - 10.255.255.255
is_rfc1918_guarded({10,_,_,_}) ->
	true;
% RFC 1918, 172.16.0.0 - 172.31.255.255
is_rfc1918_guarded({172,I1,_,_}) when I1 > 15, I1 < 32 ->
	true;
% RFC 1918, 192.168.0.0 - 192.168.255.255
is_rfc1918_guarded({192,168,_,_}) ->
	true;
is_rfc1918_guarded(_) ->
	false.

%%
%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

is_rfc1918_test_() ->
	[
		{"test for localhost",
			fun() -> ?assertEqual(true, is_rfc1918({127,1,2,3})) end
		},
		{"test for 10.x.x.x subnet",
			fun() -> ?assertEqual(true, is_rfc1918({10,0,127,3})) end
		},
		{"test for 172.x.x.x subnet",
			fun() -> ?assertEqual(true, is_rfc1918({172,16,127,3})) end
		},
		{"test for 192.168.x.x subnet",
			fun() -> ?assertEqual(true, is_rfc1918({192,168,127,3})) end
		},
		{"test #1 for non-RFC1918 subnet",
			fun() -> ?assertEqual(false, is_rfc1918({172,168,127,3})) end
		},
		{"test #2 for non-RFC1918 subnet",
			fun() -> ?assertEqual(false, is_rfc1918({192,169,127,3})) end
		},
		{"test for non-IPv4 subnet",
			fun() -> ?assertThrow({error, "Not a valid IPv4 address"}, is_rfc1918("::1")) end
		}
	].

-endif.
