-module(tpke_pubkey).

-record(pubkey, {
          players :: pos_integer(),
          k :: non_neg_integer(),
          curve :: curve(),
          g1 :: erlang_pbc:element(),
          g2 :: erlang_pbc:element(),
          verification_key :: erlang_pbc:element(),
          verification_keys :: [erlang_pbc:element(), ...]
         }).

-record(pubkey_serialized, {
          players :: pos_integer(),
          k :: non_neg_integer(),
          curve :: curve(),
          g1 :: binary(),
          g2 :: binary(),
          verification_key :: binary(),
          verification_keys :: [binary(), ...]
         }).

-type curve() :: 'SS512' | 'MNT159' | 'MNT224'.
-type pubkey() :: #pubkey{}.
-type pubkey_serialized() :: #pubkey_serialized{}.
-type ciphertext() :: {erlang_pbc:element(), binary(), erlang_pbc:element()}.

-export_type([pubkey/0, ciphertext/0, curve/0, pubkey_serialized/0]).
-export([init/7,
         lagrange/3,
         encrypt/2,
         verify_ciphertext/2,
         verify_share/3,
         combine_shares/3,
         hash_message/2,
         verify_signature/3,
         combine_signature_shares/3,
         combine_verified_signature_shares/2,
         verify_signature_share/3,
         deserialize_element/2,
         verification_key/1,
         serialize/1,
         deserialize/1]).

-export([hashH/2]).

%% Note: K can be 0 here, meaning every player is honest.
-spec init(pos_integer(), non_neg_integer(), erlang_pbc:element(), erlang_pbc:element(), erlang_pbc:element(), [erlang_pbc:element(), ...], curve()) -> pubkey().
init(Players, K, G1, G2, VK, VKs, Curve) ->
    erlang_pbc:pairing_pp_init(G1),
    erlang_pbc:element_pp_init(G1),
    #pubkey{players=Players, k=K, verification_key=VK, verification_keys=VKs, g1=G1, g2=G2, curve=Curve}.

%% Section 3.2.2 Baek and Zheng
%% Epk(m):
%% Note: V is a binary, this is by design in the paper.
-spec encrypt(pubkey(), binary()) -> ciphertext().
encrypt(PubKey, Message) when is_binary(Message) ->
    32 = byte_size(Message),
    %% r is randomly chosen from ZZ∗q
    R = erlang_pbc:element_random(erlang_pbc:element_new('Zr', PubKey#pubkey.verification_key)),
    %% U = rP
    U = erlang_pbc:element_mul(R, PubKey#pubkey.g1),
    %% V = G(rY)⊕m
    V = xor_bin(hashG(erlang_pbc:element_mul(R, PubKey#pubkey.verification_key)), Message),
    %% W = rH(U, V)
    W = erlang_pbc:element_mul(R, hashH(U, V)),
    %% ciphertext C = (U, V, W)
    {U, V, W}.

%% Section 3.2.2 Baek and Zheng
%% common code to verify ciphertext is valid
-spec verify_ciphertext(pubkey(), ciphertext()) -> boolean().
verify_ciphertext(PubKey, {U, V, W}) ->
    %% H = H(U, V)
    H = hashH(U, V),
    %% check if ˆe(P, W) = ˆe(U, H)
    erlang_pbc:element_cmp(erlang_pbc:element_pairing(PubKey#pubkey.g1, W),
                           erlang_pbc:element_pairing(U, H)).

%% Section 3.2.2 Baek and Zheng
%% Vvk(C, Di):
-spec verify_share(pubkey(), tpke_privkey:share(), ciphertext()) -> boolean().
verify_share(PubKey, {Index, Share}, {U, V, W}) ->
    true = 0 =< Index andalso Index < PubKey#pubkey.players,
    case verify_ciphertext(PubKey, {U, V, W}) of
        true when Share == '?' ->
            false;
        true ->
            %% check if ˆe(P, Ui) = ˆe(U, Yi).
            Yi = lists:nth(Index+1, PubKey#pubkey.verification_keys),
            erlang_pbc:element_cmp(erlang_pbc:element_pairing(PubKey#pubkey.g2, Share),
                                   erlang_pbc:element_pairing(U, Yi));
        false when Share == '?' ->
            true;
        false ->
            false
    end.

%% Section 3.2.2 Baek and Zheng
%% SCvk(C,{Di}i∈Φ):
-spec combine_shares(pubkey(), ciphertext(), [tpke_privkey:share(), ...]) -> binary() | undefined.
combine_shares(PubKey, {U, V, W}, Shares) ->
    {Indices, _} = lists:unzip(Shares),
    Set = ordsets:from_list(Indices),
    MySet = ordsets:from_list(lists:seq(0, PubKey#pubkey.players - 1)),
    true = ordsets:is_subset(Set, MySet),

    case verify_ciphertext(PubKey, {U, V, W}) of
        true ->
            %% m=G(∑i∈ΦλΦ0iUi)⊕V
            Bleh = [ erlang_pbc:element_pow(Share, lagrange(PubKey, Set, Index)) || {Index, Share} <- Shares, Share /= '?'],
            Res = lists:foldl(fun(E, Acc) ->
                              erlang_pbc:element_mul(Acc, E)
                      end, hd(Bleh), tl(Bleh)),
            xor_bin(hashG(Res), V);
        false ->
            undefined
    end.


%% Section 3.1 Boldyreva
%% Decisional Diffie-Hellman (DDH) problem.
-spec verify_signature_share(pubkey(), tpke_privkey:share(), erlang_pbc:element()) -> boolean().
verify_signature_share(PubKey, {Index, Share}, HM) ->
    true = 0 =< Index andalso Index < PubKey#pubkey.players,
    Y = lists:nth(Index+1, PubKey#pubkey.verification_keys),
    %% In order to verify the validity of a candidate signature σ of a messageM,
    %% a verifier simply checks whether (g,y,H(M),σ) is a valid Diffie-Hellman tuple.
    %% Given (g,g^x,g^y,g^z) it is possible to check z=xy if e(g,g^z) == e(g^x,g^y)
    erlang_pbc:element_cmp(erlang_pbc:element_pairing(PubKey#pubkey.g2, Share),
                           erlang_pbc:element_pairing(Y, HM)).

%% Section 3.2 Boldyrevya
%% V(pk,M,σ) :
-spec verify_signature(pubkey(), erlang_pbc:element(), erlang_pbc:element()) -> boolean().
verify_signature(PubKey, Signature, H) ->
    %% VDDH(g,y,H(M),σ)
    %% VDDH(g,pkL,H(M),σ)
    A = erlang_pbc:element_pairing(Signature, PubKey#pubkey.g2),
    B = erlang_pbc:element_pairing(H, PubKey#pubkey.verification_key),
    erlang_pbc:element_cmp(A, B).

-spec combine_signature_shares(pubkey(), [tpke_privkey:share(), ...], binary() | erlang_pbc:element()) -> {ok, erlang_pbc:element()} | {error, bad_signature_share}.
combine_signature_shares(PubKey, Shares, Msg) when is_binary(Msg) ->
    combine_signature_shares(PubKey, Shares, hash_message(PubKey, Msg));
combine_signature_shares(PubKey, Shares, HM) ->
    {Indices, _} = lists:unzip(Shares),
    Set = ordsets:from_list(Indices),
    MySet = ordsets:from_list(lists:seq(0, PubKey#pubkey.players - 1)),
    true = ordsets:is_subset(Set, MySet),

    case lists:all(fun({Index, Share}) -> verify_signature_share(PubKey, {Index, Share}, HM) end, Shares) of
        true ->
            %% pkL= Πj∈J(pkj) =Πj∈J(gxj)
            Bleh = [ erlang_pbc:element_pow(Share, lagrange(PubKey, Set, Index)) || {Index, Share} <- Shares],
            Res = lists:foldl(fun(E, Acc) ->
                                      erlang_pbc:element_mul(E, Acc)
                              end, hd(Bleh), tl(Bleh)),
            erlang_pbc:pairing_pp_init(Res),
            {ok, Res};
        false ->
            {error, bad_signature_share}
    end.

%% if you've verified the shares as you've received them and don't need/want to reverify them
-spec combine_verified_signature_shares(pubkey(), [tpke_privkey:share(), ...]) -> {ok, erlang_pbc:element()}.
combine_verified_signature_shares(PubKey, Shares) ->
    {Indices, _} = lists:unzip(Shares),
    Set = ordsets:from_list(Indices),
    MySet = ordsets:from_list(lists:seq(0, PubKey#pubkey.players - 1)),
    true = ordsets:is_subset(Set, MySet),

    %% pkL= Πj∈J(pkj) =Πj∈J(gxj)
    Bleh = [ erlang_pbc:element_pow(Share, lagrange(PubKey, Set, Index)) || {Index, Share} <- Shares],
    Res = lists:foldl(fun(E, Acc) ->
                              erlang_pbc:element_mul(E, Acc)
                      end, hd(Bleh), tl(Bleh)),
    erlang_pbc:pairing_pp_init(Res),
    {ok, Res}.

%% H(M)
-spec hash_message(pubkey(), binary()) -> erlang_pbc:element().
hash_message(PubKey, Msg) ->
    Res = erlang_pbc:element_from_hash(erlang_pbc:element_new('G1', PubKey#pubkey.verification_key), Msg),
    erlang_pbc:element_pp_init(Res),
    erlang_pbc:pairing_pp_init(Res),
    Res.


-spec deserialize_element(pubkey(), binary()) -> erlang_pbc:element().
deserialize_element(PubKey, Binary) when is_binary(Binary) ->
    erlang_pbc:binary_to_element(PubKey#pubkey.verification_key, Binary).


-spec lagrange(pubkey(), ordsets:ordset(non_neg_integer()), non_neg_integer()) -> erlang_pbc:element().
lagrange(PubKey, Set, Index) ->
    true = ordsets:is_set(Set),
    %true = PubKey#pubkey.k == ordsets:size(Set),
    MySet = ordsets:from_list(lists:seq(0, PubKey#pubkey.players - 1)),
    true = ordsets:is_subset(Set, MySet),

    true = ordsets:is_element(Index, Set),
    true = 0 =< Index andalso Index < PubKey#pubkey.players,

    One = erlang_pbc:element_set(erlang_pbc:element_new('Zr', PubKey#pubkey.verification_key), 1),

    Num = lists:foldl(fun(E, Acc) ->
                              erlang_pbc:element_mul(Acc, E)
                      end, One, [ 0 - JJ  - 1 || JJ <- ordsets:to_list(Set), JJ /= Index]),

    Den = lists:foldl(fun(E, Acc) ->
                              erlang_pbc:element_mul(Acc, E)
                      end, One, [ Index - JJ  || JJ <- ordsets:to_list(Set), JJ /= Index]),

    erlang_pbc:element_div(Num, Den).

-spec hashG(erlang_pbc:element()) -> binary().
hashG(G) ->
    crypto:hash(sha256, erlang_pbc:element_to_binary(G)).

-spec hashH(erlang_pbc:element(), binary()) -> erlang_pbc:element().
hashH(G, X) ->
    32 = byte_size(X),
    erlang_pbc:element_from_hash(erlang_pbc:element_new('G2', G), list_to_binary([erlang_pbc:element_to_binary(G), X])).

-spec xor_bin(binary(), binary()) -> binary().
xor_bin(A, B) ->
    32 = byte_size(A),
    32 = byte_size(B),
    xor_bin(A, B, []).

-spec xor_bin(binary(), binary(), [byte()]) -> binary().
xor_bin(<<>>, <<>>, Acc) ->
    list_to_binary(lists:reverse(Acc));
xor_bin(<<A:8/integer-unsigned, T1/binary>>, <<B:8/integer-unsigned, T2/binary>>, Acc) ->
    xor_bin(T1, T2, [A bxor B | Acc]).

-spec verification_key(pubkey()) -> erlang_pbc:element().
verification_key(Pubkey) ->
    Pubkey#pubkey.verification_key.

-spec serialize(pubkey()) -> pubkey_serialized().
serialize(#pubkey{players=Players, k=K, curve=Curve, g1=G1, g2=G2, verification_key=VK, verification_keys=VKs}) ->
    #pubkey_serialized{players=Players,
                       k=K,
                       curve=Curve,
                       g1=erlang_pbc:element_to_binary(G1),
                       g2=erlang_pbc:element_to_binary(G2),
                       verification_key=erlang_pbc:element_to_binary(VK),
                       verification_keys=[erlang_pbc:element_to_binary(V) || V <- VKs]}.

-spec deserialize(pubkey_serialized()) -> pubkey().
deserialize(#pubkey_serialized{players=Players, k=K, curve=Curve, g1=G1, g2=G2, verification_key=VK, verification_keys=VKs}) ->
    Group = erlang_pbc:group_new(Curve),
    Element = erlang_pbc:element_new('G1', Group),
    #pubkey{players=Players,
            k=K,
            curve=Curve,
            g1=erlang_pbc:binary_to_element(Element, G1),
            g2=erlang_pbc:binary_to_element(Element, G2),
            verification_key=erlang_pbc:binary_to_element(Element, VK),
            verification_keys=[erlang_pbc:binary_to_element(Element, V) || V <- VKs]}.
