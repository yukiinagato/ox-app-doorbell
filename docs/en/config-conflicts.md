# Retained configuration conflicts

Local revision checks prevent concurrent writers on one node from silently replacing each other. Disconnected nodes still use the existing LWW configuration replication: the effective value may change on reconnect. Upgraded configuration writers additionally retain administrator intent and expose unresolved alternatives in the Admin page. They do not automatically merge or repeatedly rewrite the winning value.

## Records and atomicity

The existing SQLite configuration transaction stores ordinary mutations and immutable `_config_changes.<change_id>.<sha256>` records together. A failed write publishes neither. SHA-256 binds the serialized record; authentication and confidentiality come from the existing Mesh SecureChannel, not from this digest. Records are excluded from ordinary configuration, exported settings, rule evaluation and executable events. Metadata is strictly validated at ingress; unknown fields, duplicates, cycles, mismatched author/digest and invalid parent versions reject the batch without advancing its durable frontier.

Version 1 records contain a random 128-bit `change_id`, `author_node`, `entity`, `base_entity_version`, `parents`, typed `ops`, `candidate_exists`, `candidate`, and `requires_reentry`. Every operation has its key, set/delete intent and at most two base LWW versions: its nearest existing ancestor and exact record, with `{key,hlc,author,seq,deleted}`. Sequence numbers are decimal strings. A missing parent denotes an absent record. The entity digest covers all prior LWW record identities in that entity. A record has at most 256 operations and 64 KiB encoded content.

Entities are configuration sections (the first path component), except that each `devices.<id>` is separate. Root `devices` writes and deletes are rejected; write a specific device instead. Section granularity conservatively flags different-field edits on separate branches as well. All public single, batch, conditional, import and announcement configuration writes share the journal boundary. Bootstrap/runtime maintenance and credential-service operations keep their existing separate contracts. Old nodes do not retain their own editing intent; a mixed fleet cannot claim complete conflict protection.

## Visibility and resolution

`GET /api/config/snapshot` includes `edit_conflicts` and `edit_journal` beside the existing configuration and revision. Each conflict identifies an entity, every current head, the effective value, and retained branch records. `candidate_exists:false` is deletion; `candidate_exists:true` with null is a real null value. The same snapshot is available through the existing native ABI.

Ordinary edits to an unresolved entity return `unresolved_config_conflict`. Resolution uses the existing authenticated, CSRF/Origin-protected conditional commit. Supply `resolves:{"entity":["all-current-head-ids"]}` and a set/delete operation for that exact entity. A resolving set replaces its full value, including removing omitted fields and superseded descendant records. It still passes current configuration validation. The server checks both the current revision and exact head set in the transaction; stale choices fail without an automatic overwrite. The resulting record references all candidates. Repeated synchronization does not create new records.

Protected values are replaced by `requires_reentry` markers. Valid `secret:` references remain available; plaintext credentials and credential-bearing URLs do not enter candidates. An incomplete redacted candidate cannot be directly committed as a resolution. Re-enter protected settings through the existing secure-storage/reference flow. Resolving a conflict does not recreate a missing platform secret.

## Bounded retention

Local history allows 512 records total, 64 per entity and 512 KiB total encoded record bytes. Remote unions reserve 1024 records, 128 per entity and 1 MiB. A full local history returns `config_history_capacity_exceeded` without publishing the edit. A remote invalid or oversized union retains the previous state and exposes an error in `runtime.config_store`; synchronization can retry after the underlying condition is addressed.

Ordinary event retention and tombstone cleanup never remove retained edit records. This first implementation also retains resolved ancestry: it has no coverage-proven history compactor. Capacity can therefore block further edits or resolution, rather than discard unresolved alternatives. Increasing bounds or introducing safe archive/compaction requires separate resource and recovery qualification. Normal configuration export excludes this history and platform secrets; it is not a complete disaster-recovery backup.
