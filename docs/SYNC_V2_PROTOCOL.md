# Midas private hub protocol v2

All paths remain private Tailscale HTTPS (loopback HTTP for tests). Existing v1 remains supported. Every route except pairing request/status requires the existing scoped bearer credential. Every normal response uses no-store; large responses negotiate gzip; uncompressed page and request sizes are bounded.

## Manifest

GET /v2/manifest returns:

    {protocolVersion:2, hubVersion:"0.49.0", workspace:<v1 workspace>,
     limits:{pageBytes:1048576, publicationRecords:2000000, publicationBytes:536870912, storageBytes:8589934592},
     devices:[<head>], receipts:[<reader receipt>], checkedAt:<Apple epoch seconds>}

Head:

    {deviceID:<UUID>, deviceName:<name>, revision:<integer >=1>, digest:<sha256 semantic digest>,
     header:{schemaVersion:1, workspaceID,deviceID,deviceName,publishedAt,excludedRecords},
     pages:[{digest:<sha256 raw decoded page bytes>,byteCount,eventCount,accountDayCount}],
     eventCount,accountDayCount, revoked:<bool>, supportsReceipts:<bool>,
     leaseExpiresAt:<Apple epoch>,legacyViewStale:<bool>}

Pages are ordered; each is exactly JSON {schemaVersion:1,events:[v1 events],accountDays:[v1 account rows]}. No device/publication timestamp is part of a page. Device event IDs and all numeric validation retain v1 semantics. GET /v2/pages/{deviceID}/{revision}/{digest} fetches one exact immutable page body. Current canonical heads are always retained. Older revisions remain for at least 24 hours, and each manifest renews a 24-hour resume lease for its selected heads. An interrupted bootstrap can resume its pinned revision during that lease. Hourly maintenance reclaims expired revision pages and abandoned stages, preserving all current canonical records. Fetching an expired revision returns HTTP410 {error:"revision_expired"}; restart from a fresh manifest. Unique stored page bytes are capped at 8GiB; capacity errors never delete current canonical records. Clients validate hash, byte count, counts, duplicate identities and complete publication before applying.

## Staged upload

POST /v2/upload/start:

    {uploadID:<client UUID, reused on retry>,expectedRevision:<integer >=0>,
     header:<v1 publication without events/accountDays>,pages:[<ordered page descriptors>]}

Response:

    {uploadID,missingDigests:[sha256],committed:<bool>,receipt:<receipt if committed>}

The hub enforces caller device/workspace, validates bounds and compares expectedRevision with the current head. A retry with the same uploadID and same specification is idempotent; a different specification conflicts. POST /v2/upload/page/{uploadID}/{digest} accepts exact raw page bytes, verifies SHA256 and page fields, then durably stores them. Response {stored:true,digest}. Upload stages expire after one hour if not committed; committed receipt retries remain available for 30 days.

POST /v2/upload/commit with {uploadID} atomically CAS-publishes the prepared pages and returns:

    {deviceID,revision,digest,acceptedAt:<Apple epoch>,publicationSucceeded:true}

CAS conflict is HTTP409 {error:"revision_conflict"}; the caller must fetch/reconcile its current head and start a new uploadID. No advancing merely by wall-clock timestamp. Committed retry returns the original receipt even if a subsequent upload advanced the head. Equal semantic data does not increment revision; receipt/heartbeat metadata do not generate data changes.

Legacy v1 records are migrated additively into revision/page tables; original snapshots remain. v2 commit disallows omission of any previous canonical IDs, regardless of age including legacy aggregates when fine source rows are rehydrated. Canonical storage retains both kinds of evidence; derived display and v1 views conservatively choose a whole provider/day set whose token, request and money totals cover the legacy baseline. Until an explicit deletion protocol exists, ordinary missing source rows are not deletion. A server rejects suspicious loss with HTTP409 {error:"history_omission"} and rejects same-identity losing revisions with HTTP409 {error:"history_regression"}; caller must preserve/reconcile its own published history.

## Peer applied receipt

POST /v2/receipt with {appliedRevisions:{"<device UUID>":<revision>}} after the client durably applies the complete selected checkpoint. It returns {deviceID,appliedRevisions,checkedAt}. The server validates every referenced revision is positive and no newer than that device’s current gapless committed sequence. Receipt metadata remains valid after old page leases expire. Manifest receipts use the same shape and are keyed by authenticated reader; they never advance semantic revision. A v1-only device has no receipt and cannot be claimed caught up.

## Other errors and fallback

HTTP401/403 auth/device failure, HTTP409 workspace/revision/history conflict, HTTP413 capacity/page bound, HTTP400 validation, HTTP404 missing route/page, HTTP410 expired pinned revision. Only an HTTP404 from initial GET /v2/manifest permits fallback to v1. A missing page during pinned bootstrap must restart manifest reconciliation, never silently fall back or accept partial history. Compressed responses preserve decoded-size enforcement on the client.

## Pairing

POST /v2/pairing/request (no bearer, still private tailnet, no Origin) with {deviceName,requestID:<client UUID>,requestSecret:<32..256 URL-safe chars>,endpoint:<verified .ts.net origin>} returns {requestID,code:<6 digits>,expiresAt,status:"pending"}. Up to five requests in a five-minute window; each expires after five minutes. POST /v2/pairing/status with {requestID,requestSecret} returns pending/denied/expired or approved with connection:<v1 enrollment>; an approved enrollment can be retrieved for five minutes by that same unguessable request secret for retry.

Approval is exclusively local CLI on the hub host: pairing-list, pairing-approve --request-id UUID --code CODE, pairing-deny --request-id UUID. Existing remote sync credentials cannot approve themselves or execute host commands. Newly issued credentials remain per-device and revocable. Credentials are never printed by pairing-list or approval; only the requesting device with requestSecret receives its enrollment over HTTPS.

## Compatibility and diagnostics

Every v2 commit derives a bounded v1 day/model/provenance/priced rollup view using the existing rollup identity format; it never substitutes rollups for canonical v2 event identities. Imported legacy and rehydrated fine evidence are not summed together. Fine rows replace a legacy provider/day view only when their tokens, requests, cost and API-equivalent cost each cover known legacy totals. Missing optional numeric values remain missing unless at least one contributing value is known. If v1 validation or global legacy capacity prevents a fresh projection, preserve the prior original and advertise legacyViewStale=true; the v2 commit and canonical history remain valid.

Hub version, negotiated capacities, revision counts, receipt capability, checkpoint leases and legacy-view coverage are authenticated diagnostics in the manifest. No secret or arbitrary execution endpoint is exposed. supportsReceipts becomes true after a v2 commit or applied receipt; an old v1 collector remains false. Semantic revisions omit publication and account fetch timestamps, while exact page hashes cover all page bytes.

Values may include pricingRevision, a nonnegative integer up to 2147483647; missing legacy values mean revision zero. Same-identity winner order is event tokens, observedAt, pricingRevision, pricing quality, deterministic encoded-row tie break; account rows omit token precedence. Derived rollups carry the maximum input pricingRevision. Canonical history has no age-based deletion; resume metadata expiry only reclaims older versions of records retained in current heads.
