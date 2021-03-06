-module(tpke_privkey).

-record(privkey, {
          pubkey :: tpke_pubkey:pubkey(),
          secret_key :: erlang_pbc:element(),
          secret_key_index :: non_neg_integer()
         }).

-record(privkey_serialized, {
          pubkey :: tpke_pubkey:pubkey_serialized(),
          secret_key :: binary(),
          secret_key_index :: non_neg_integer()
         }).

-opaque privkey() :: #privkey{}.
-opaque privkey_serialized() :: #privkey_serialized{}.
-type share() :: {non_neg_integer(), erlang_pbc:element()}.

-export_type([privkey/0, share/0, privkey_serialized/0]).

-export([init/3, decrypt_share/2, sign/2, public_key/1, serialize/1, deserialize/1]).

-spec init(tpke_pubkey:pubkey(), erlang_pbc:element(), non_neg_integer()) -> privkey().
init(PubKey, SecretKey, SecretKeyIndex) ->
    #privkey{pubkey=PubKey, secret_key=SecretKey, secret_key_index=SecretKeyIndex}.

%% Section 3.2.2 Baek and Zheng
%% Dski(C):
-spec decrypt_share(privkey(), tpke_pubkey:ciphertext()) -> share().
decrypt_share(PrivKey, CipherText) ->
    {U, _V, _W} = tpke_pubkey:check_ciphertext(PrivKey#privkey.pubkey, CipherText),
    %% computes Ui = xiU
    Share = erlang_pbc:element_mul(PrivKey#privkey.secret_key, U),
    %% output Di = (i, Ui)
    {PrivKey#privkey.secret_key_index, Share}.

%% Section 5.2 Boldyrevya
%% MS
-spec sign(privkey(), erlang_pbc:element()) -> share().
sign(PrivKey, H) ->
    %% σj←H(M)^xj
    %% Note that H(M) has already been computed here
    {PrivKey#privkey.secret_key_index, erlang_pbc:element_pow(H, PrivKey#privkey.secret_key)}.

-spec public_key(privkey()) -> tpke_pubkey:pubkey().
public_key(PrivKey) ->
    PrivKey#privkey.pubkey.

-spec serialize(privkey()) -> privkey_serialized().
serialize(#privkey{pubkey=PubKey, secret_key=SK, secret_key_index=SKI}) ->
    #privkey_serialized{pubkey=tpke_pubkey:serialize(PubKey), secret_key=erlang_pbc:element_to_binary(SK), secret_key_index=SKI}.

-spec deserialize(privkey_serialized()) -> privkey().
deserialize(#privkey_serialized{pubkey=PubKey, secret_key=SK, secret_key_index=SKI}) ->
    DeserializedPubKey = tpke_pubkey:deserialize(PubKey),
    #privkey{pubkey=DeserializedPubKey, secret_key=tpke_pubkey:deserialize_element(DeserializedPubKey, SK), secret_key_index=SKI}.
