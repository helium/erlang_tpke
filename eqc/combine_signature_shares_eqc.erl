-module(combine_signature_shares_eqc).

-include_lib("eqc/include/eqc.hrl").

-export([prop_combine_signature_shares/0]).

prop_combine_signature_shares() ->
    ?FORALL({{Players, Threshold}, Curve, Fail}, {gen_players_threshold(), gen_curve(), gen_failure_mode()},
            begin
                {ok, _} = dealer:start_link(Players, Threshold, Curve),
                {ok, K} = dealer:adversaries(),
                {ok, _Group} = dealer:group(),
                {ok, _G1, G2, PubKey, PrivateKeys} = dealer:deal(),
                FailPKeys = case Fail of
                    wrong_key ->
                        {ok, _, _, _, PKs} = dealer:deal(),
                        PKs;
                    _ ->
                        PrivateKeys
                end,
                MessageToSign = tpke_pubkey:hash_message(PubKey, crypto:hash(sha256, crypto:strong_rand_bytes(12))),
                FailMessage = case Fail of
                                  wrong_message ->
                                      tpke_pubkey:hash_message(PubKey, crypto:hash(sha256, crypto:strong_rand_bytes(12)));
                                  _ ->
                                      MessageToSign
                              end,
                Signatures = [ tpke_privkey:sign(PrivKey, MessageToSign) || PrivKey <- PrivateKeys],
                FailSignatures = [ tpke_privkey:sign(PrivKey, FailMessage) || PrivKey <- FailPKeys],
                Shares = case Fail of
                             duplicate_shares ->
                                 %% provide K shares, but with a duplicate
                                 %% XXX this breaks when k=1 obviously, so it is commented out for now
                                 [S|Ss] = dealer:random_n(K, Signatures),
                                 [S, S | tl(Ss)];
                             none -> dealer:random_n(K, Signatures);
                             _ ->
                                 %% either wrong_message or wrong_key
                                 dealer:random_n(K-1, Signatures) ++ dealer:random_n(1, FailSignatures)
                         end,
                Sig = tpke_pubkey:combine_signature_shares(PubKey, Shares),
                gen_server:stop(dealer),
                SharesVerified = lists:all(fun(X) -> X end, [tpke_pubkey:verify_signature_share(PubKey, G2, Share, MessageToSign) || Share <- Shares]),
                SignatureVerified = tpke_pubkey:verify_signature(PubKey, G2, Sig, MessageToSign),
                ?WHENFAIL(begin
                              io:format("Signatures ~p~n", [[ erlang_pbc:element_to_string(S) || {_, S} <- Signatures]]),
                              io:format("Shares ~p~n", [[ erlang_pbc:element_to_string(S) || {_, S} <- Shares]])
                          end,
                          conjunction([
                                       {verify_signature_share, eqc:equals(true, (Fail /= none) /= SharesVerified)},
                                       {verify_combine_signature_shares, eqc:equals(true, (Fail /= none) /= SignatureVerified)}
                                      ]))
            end).

gen_players_threshold() ->
    ?SUCHTHAT({Players, Threshold},
              ?LET({X, Y},
                   ?SUCHTHAT({A, B}, {int(), int()}, A > 0 andalso B >= 0 andalso A > B),
                   {X*3, X - Y}),
              Players > 3*Threshold+1).

gen_curve() ->
    %elements(['SS512', 'MNT224']).
    elements(['SS512']).

gen_failure_mode() ->
    elements([none, wrong_message, wrong_key]).%%, duplicate_shares]).
