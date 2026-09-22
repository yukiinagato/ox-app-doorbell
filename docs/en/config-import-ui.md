# Importing and exporting configuration in the administrator UI

Open **System → Export / Import**. Export downloads a version 2 JSON document
with the source node/application version and a content-scope label. It contains
configuration and valid `secret:` references, not secure-storage values or asset
files. Legacy password/token/private-key fields and credential-bearing URLs are
omitted; `excluded_paths` records the omissions. Unrelated text is retained.
No redaction placeholder is substituted for a credential. This file is not a
complete recovery backup.

Choose a JSON file or paste its contents, then select **Preview import**. Version
2 exports, raw configuration objects and legacy entry arrays are converted to
the [staged import protocol](config-import.md). Unsupported versions, duplicate
JSON members, reserved prototype keys and oversized inputs are rejected before
staging. Ordinary configuration writes retain their existing 256-operation
limit; this flow can restore more than 256 entries within the Core's import and
history limits.

By default, imported fields merge into a fresh snapshot; absent fields remain.
The explicit complete-replacement option removes absent fields. Review the
changed fields and deletions, missing secret references, missing assets and
export omissions. Preflight does not modify live configuration. Missing
references/assets or invalid configuration prevent confirmation. Restore secret
values through the existing Integrations or platform secure-storage setup, and
upload asset files through Assets; then discard the old preview and prepare a
new one. Never paste secret values into the configuration document. A changed
configuration revision requires another explicit preview, not an automatic
rewrite.

The confirmation checkbox names the deletion count and the local target. Only
**Apply reviewed import** creates the random operation identity and submits the
commit. The UI stores a non-sensitive recovery handle in this tab's session
storage before sending: schema version, operation ID, stage token, digest and
node ID. File contents, credentials and the preview are not stored there. Keep
a copy of the displayed handle if the browser tab will be closed. Authentication
expiry clears file input and preserves the handle; preflight must be repeated
when its initiating session is no longer valid.

A missing, invalid or interrupted commit response means **result unknown**.
**Check this import result** queries the same operation on its original node;
it cannot commit a stage. Reloading the tab restores only this query context.
No new operation is submitted automatically. If no receipt is found, the result
remains unknown. To prepare another import, explicitly acknowledge that the old
reference has been saved and its result remains unknown. The old reference
stays visible while reviewing the next import; committing the next import
replaces the tab's saved handle. A fresh login after restart can query a receipt
only while the original administrator credential remains valid.

Success means that this node durably committed the import. Other nodes'
configuration synchronization is explicitly **unverified**: the current protocol
has no public acknowledgement for a particular revision on each peer. The
separately displayed online/known-peer count reports observed connections only.
It never represents synchronization progress or cluster-wide success.
