-module(serialize_deserialize_test).

-include_lib("eunit/include/eunit.hrl").

simple_test() ->
    {ok, Dealer} = dealer:new(),
    {ok, _Group} = dealer:group(Dealer),
    {ok, {PubKey, PrivateKeys}} = dealer:deal(Dealer),

    SerializedPubKey = tpke_pubkey:serialize(PubKey),
    SerializedPvtKeys = [tpke_privkey:serialize(PK) || PK <- PrivateKeys],
    Foo = hd(SerializedPvtKeys),
    ?assertEqual(SerializedPubKey, tpke_pubkey:serialize(tpke_privkey:public_key(tpke_privkey:deserialize(Foo)))),
    ok.
