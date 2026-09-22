# Authenticated operation acknowledgement v1

This optional extension to [the operation API](operation-api.md) is disabled by
default. It uses standard Ed25519 verification from the repository's existing
Monocypher implementation. It adds no encryption algorithm, key-exchange scheme,
consensus protocol, broker, or automatic command retry.

## Commissioning and revocation

A door can configure this complete object at `doors.<door>.operations.ack`:

```json
{"protocol":"ed25519-v1","actuator_id":"front-lock","public_key":"<64 lowercase hex characters>"}
```

The public key is a 32-byte Ed25519 verification key, not a secret. The signing
key belongs only to the actuator and must never enter replicated configuration,
Core logs, or a backup. Missing/incomplete configuration disables ACK support.
Unknown fields, duplicate fields, other protocols, invalid hex, the zero public
key, and actuator IDs outside 1–64 ASCII letters/digits/underscore/hyphen are
rejected. Leaf edits remain fail closed until the complete valid object exists.
An administrator can revoke ACK authority by deleting or replacing this object.
The receiver checks the current object as well as the key and actuator identity
frozen at prepare; key rotation does not authorize a new key to confirm an old
operation. A removed/reassigned door, changed command, changed broker/topic
binding or changed fixed authority cannot be confirmed through its old binding.

Configuration states only which source may authenticate an ACK. It does not
advertise that a physical actuator has been qualified, that its deduplication is
reliable, or that a door sensor exists. Commissioning a real actuator requires
separate integration/hardware qualification. A local test executor is not that
qualification.

## Command and ACK envelope

For a commissioned actuator the one outgoing MQTT command includes the existing
`operation_id`, `authority_node`, and `door`, plus `ack_protocol: "ed25519-v1"`,
`actuator_id`, and `command_digest`. The command digest is lowercase SHA-256 of
these exact UTF-8/ASCII bytes, including the final newline:

```text
ox-doorbell/operation-command/v1\n
<door>\n
<command>\n
<broker-binding-digest>\n
```

Here each `\n` denotes one newline byte, not a backslash and letter. The broker
binding digest is the existing prepare-time SHA-256 binding of broker host,
port and base topic. Door, command and binding encodings forbid newlines.

The actuator publishes a non-retained JSON object on `<base_topic>/cmd/ack`:

```json
{"protocol":"ed25519-v1","operation_id":"<32 hex>","authority_node":"<32 hex>","actuator_id":"front-lock","door":"front","command_digest":"<64 hex>","result":"command_processed","signature":"<128 hex>"}
```

The ACK is at most 2048 bytes, one flat object, exactly the eight listed string
fields, with no duplicate/unknown fields. Operation and authority IDs are
32 lowercase hex characters; command digest is 64; signature is 128. Door IDs
follow the operation API. `command_processed` is the only result in v1. Retained
ACKs are not accepted. An ordinary door-open sensor message or a legacy ACK with
no authenticated ID is not an operation acknowledgement.

The detached Ed25519 signature covers these exact bytes:

```text
ox-doorbell/operation-ack/v1\n
<operation_id>\n
<authority_node>\n
<actuator_id>\n
<door>\n
<command_digest>\n
command_processed\n
```

Every variable is validated before constructing this domain-separated payload;
all delimiters are forbidden inside fields. JSON ordering, escaping or whitespace
is not signed. The protocol never signs an ambiguous JSON serialization. The
reference test executor independently implements the published byte format and
uses a recognizable test-only key.

## Verification, state and timeouts

The Core MQTT callback runs on its state loop. A valid signature alone is
insufficient: the receiver must still be the configured authority, the current
actuator/key/door/command/endpoint must match the prepare-time frozen intent,
and the ledger must prove that this exact ID acquired dispatch. A signature for
another ID, authority, door, actuator or digest is rejected. A prepared or
unstarted terminal record cannot become acknowledged. Duplicate ACKs settle the
same record without another dispatch. A late valid ACK may settle an unknown
record, including after restart, while changing no other door's operation.

`actuator_ack` means that the authenticated actuator reports processing this
command. It does not mean the door physically opened, nor that an uncorrelated
sensor transition was caused by the command. The API continues to identify each
operation explicitly; a UI must match both operation and authority IDs before
updating a current view. Without a measured sensor, physical door state remains
unconfirmed. This task does not invent a sensor publication API.

A configured ACK has a four-second monotonic wait after adapter admission. If
it does not arrive, the same ledger row becomes `unknown_after_dispatch` with
`unknown_reason:ack_unavailable`. A connection interruption makes outstanding
sends unknown with `transport_ambiguous`; reconnect never resends them. Without
ACK configuration, a successful admission remains `dispatched` with
`ack_unavailable`, and interruption likewise becomes unknown. At most 2048
feedback watches exist, bounded by the authority's active ledger limit. A
connection-loss sweep updates at most 32 records per loop turn. Timers and sweep
callbacks are cancelled at shutdown; restart recovery uses the existing durable
ledger rules. Unresolved rows are never silently evicted to admit more work.

Actuator-side ID deduplication must persist before the actuator's side effect.
The test executor demonstrates a bounded reference contract only; it is not
shipped to an existing Home Assistant installation. Core sends once even when an
actuator supports deduplication. Network redelivery without a qualified actuator
still prevents any end-to-end exactly-once promise. Older unsigned `cmd/ack`
messages retain no authority to mark an operation complete.

The verification key must use canonical Edwards encoding and must not be one of the eight low-order points. This rejects keys for which the bundled cofactored verifier cannot establish authentication. The fixed low-order coordinates follow the standard Ed25519 points also checked by [libsodium](https://github.com/jedisct1/libsodium/blob/1.0.18/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c#L966); verification still uses the existing Monocypher implementation.

The reference executor has a separate durable pending/completed state. A crash after claiming an ID but before recording completion yields no success ACK and no retry of the simulated action. This is a conservative unknown outcome, not exactly-once completion.
