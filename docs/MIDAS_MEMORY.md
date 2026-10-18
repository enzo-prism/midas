---
summary: Why Midas could report gigabytes of memory, the measured causes, and the scan/cache invariants that keep the footprint small.
read_when:
  - Investigating memory, footprint, or scan-cost reports.
  - Changing cost-usage scanning, caching, refresh cadence, or WebView retention.
---

# Midas memory footprint

## 0.47.1: shared-history allocation and scan persistence

The October 17 profile of 0.47.0 found a physical footprint of 1.1–1.6 GB,
with a 1.7 GB high-water mark after about 30 minutes. `leaks --noContent`
reported zero leaked bytes. The heap instead contained large JSON buffers,
several complete event arrays, and allocator fragmentation from repeated sync
processing. This is a different workload from the earlier session-scanner issue:
shared history now includes several devices and many copied events.

The fixes preserve the existing numeric schema, source identities, byte limits,
offline outbox, and pricing coverage:

- Startup reuses the decoded cache rather than reading and decoding it twice.
- Large saved snapshots and hub/folder publications use structural scanning and
  bounded decoding: at most 512 rows and 256 KiB per decoder batch. Metadata,
  keys, and individual rows are capped at 64 KiB, including unknown extension
  fields; oversized extensions are rejected. This avoids a whole-history
  Foundation JSON index while preserving normal generated snapshots and outboxes.
- Recurring history retention, ledger aggregation, and atomic cache writes run on
  one worker actor, with cancellation and connection-generation checks before
  applying results. Startup restoration still performs one synchronous decode
  and merge; this change does not claim asynchronous startup restoration.
- Ledger deduplication skips canonical JSON for identical records, uses typed
  identities, and accumulates compact day/model totals instead of retaining a
  second corpus of values. Valid record ordering and floating-point sum order
  remain deterministic.
- Export retains one event/size/heap-position table, reuses an encoder, rejects
  copied prefixes before encoding, and reuses compiled model-name validation.
- Publication validation calculates each distinct UTC day once. Stable ID hashing
  writes hexadecimal bytes directly and remains compatible with published IDs.
- Explicit autorelease pools bound codec, per-file export, and entire scan work.
  Network receive buffers reserve only a validated Content-Length and release
  their retained bytes immediately after completion.
- An unchanged Codex scan does not encode and rewrite its whole numeric cache.
  A bounded 16-path clean-scan stamp preserves throttling and includes file
  identity, size, and modification time so atomic replacement cannot inherit
  freshness from the previous file. Force refresh bypasses this throttle.

Validation covers exact ID vectors, UTC boundary timestamps, nil/zero and
overflow totals, copied sessions, capped exporter replacement, unchanged cache
writes, active appends/deletions, atomic cache replacement, slow disk writes,
disconnect cancellation, and offline restart. A fixed private numeric corpus is
also compared across both builds; source logs, credentials, and account
identities are not included in public profiling artifacts.

For future checks, compare physical footprint and its high-water mark across
several complete collection/exchange cycles. RSS alone omits compressed pages,
and a smaller live heap alone does not prove the allocator released its pages.

## Earlier scanner profiles

Why Midas could sit at 1.8 GB in Activity Monitor, what actually caused it, and the
invariants that keep the menu bar process small. Profiled October 15, 2026 against a
machine with 2.2 GB of Claude session logs (1,562 files), 2.2 GB of Codex rollout logs
(321 files), 1.7 GB of Muse session logs (1,122 files), and an 84 MB Codex trace DB.

## Symptoms vs. live memory

The running 0.46.0 process (29 h uptime) reported:

- Physical footprint **1,801 MB**, peak **4,953 MB** (`footprint`, `phys_footprint_peak`).
- `Malloc Small` dirty **1,640 MB** across ~2,490 regions.
- Live heap only **~28 MB** in ~170k allocations (`heap`, `leaks`: 0 leaks).

So there was no leak and no large retained model. The reported footprint was freed
malloc pages that stayed dirty or swapped because the allocator could not unmap
fragmented regions: a few live bytes per 16 KB page pin the whole page, and
`malloc_zone_pressure_relief` cannot reclaim partially live regions (verified
empirically: relief released 0 bytes after scans whose live set was 2 MB inside a
256 MB zone). Under system pressure the same process later purged to **118 MB**
without restarting, confirming the residue theory.

The fix is therefore not "free more" — it is **allocate less, less often, and drain
autorelease pools so transients never interleave with long-lived objects**.

## What allocated

Measured with a temporary probe driving `CostUsageScanner.loadDailyReport` over the
real logs (scratch cache, 30-day window), footprint sampled at 50 ms:

| Scan                     | Before     | After      |
| ------------------------ | ---------- | ---------- |
| Claude cold (first scan) | 25.9 s     | 25.7 s     |
| Claude warm (unchanged)  | 0.8 s      | 0.2 s      |
| Claude window slide +1 d | ~26 s (full reparse) | 0.8 s |
| Claude 60 d after 30 d   | 26.8 s (full reparse) | 0.2 s |
| Codex warm               | 8.5 s      | 7.9 s      |

Live bytes after every scan were ~2 MB once pools drained; without an explicit pool,
each Claude scan left ~145 MB of autoreleased JSON graphs alive until the thread
pool happened to drain. Reports were identical before and after (same day entries).

Drivers, in order:

0. **The Meta session-log scanner read whole files.** `MuseSessionLogScanner.loadSummary`
   loaded each Muse `session.jsonl` with `readToEnd()` (up to 140 MB per file here,
   1.7 GB total) and fully JSON-parsed every line, including multi-MB `retained_frame`
   lines, on every Meta refresh — no streaming, prefilter, pools, or cache. After the
   cost-scanner fixes shipped in 0.46.1, a fresh launch still ramped linearly to a
   **3.59 GB** footprint peak in ~21 s inside `appendResponses`. This was the largest
   single spike and much of the original residue.
1. **Window slides forced full reparses.** `requestedWindowExpandsCache` treated the
   daily forward slide of the rolling window as an expansion and set
   `forceFullScan`, bypassing per-file mtime/size freshness and incremental offsets.
   Alternating 30-day and 60-day (prior-period) requests evicted each other's rows
   via `pruneDays`, so each width reparsed the whole corpus. Up to ~3 full
   2.2 GB Claude reparses per day, each peaking at several hundred MB.
2. **Every scan rebuilt everything.** The full cache JSON (12 MB for Claude) was
   decoded, day aggregates rebuilt from all retained rows, the cache re-encoded and
   rewritten, and every retained row repriced — even when no file had changed.
3. **Autorelease accumulation.** Per-line pools existed inside the JSONL reader, but
   per-file work (cache dictionary churn, row merges, report building) ran in the
   enclosing pool for thousands of files at a time.
4. **Secondary retention.** One offscreen `WKWebView` per account data store with no
   count cap (each keeps a WebContent process), relief scheduled before the async
   usage-sync export scan ran, and no response to system memory-pressure warnings.

## Fix shipped in 0.46.2

- **Streaming Meta scanner.** `appendResponses` now streams via `CostUsageJsonl.scan`
  with a `model_completed` byte prefilter (the marker also appears inside stringified
  `record_json` children), parses from `Data` without String round-trips, and drains
  an autoreleasepool per line and per file. Measured on this machine after the fix:
  startup peak **129 MB** (was 3.59 GB), steady footprint **~50 MB**, RSS ~164 MB
  (was ~2 GB). The sync exporter's Meta path already streamed and was left as-is.

## Fixes shipped in 0.46.1

- **Backward-only full scans.** `requestedWindowExpandsBackward` gates
  `forceFullScan` for Claude, Codex, and Pi. A forward slide cannot add rows to an
  unchanged file, so freshness/incremental paths are sufficient.
- **Retained-window union (Claude).** Scans parse against the union of the requested
  and cached windows (`retainedScanRange`); only the cached-side extension is clipped
  to 92 scan days, and the retained window always covers the full requested window
  (requests up to 365 days are never truncated). Current-30d and prior-60d fetches
  share one cache; rows that age out of the union are pruned. Claude cache artifact
  bumped to `claude-v6.json` for one clean rebuild.
- **Dirty-tracked persistence (Claude).** A scan that parsed nothing skips the day
  rebuild and the whole-cache re-encode/write.
- **Report memoization.** Built reports are memoized under a content fingerprint of
  every builder input (day aggregates, repricing-relevant row fields, range, pricing
  stamp). Repeat refreshes over an unchanged cache skip reconciliation and repricing.
- **Per-file autoreleasepools** in the Claude, Codex, and Pi scan loops, and around
  cache JSON decode/encode.
- **WebView retention cap.** At most 2 idle dashboard WebViews are kept; LRU eviction
  never touches busy entries.
- **Pressure response.** `MemoryPressureMonitor` evicts cached WebViews and returns
  free malloc pages on `.warning`/`.critical`; usage-sync completion also relieves.

Regression gates live in `Tests/CodexBarTests/CostUsageRetainedWindowTests.swift`
(same-size/same-mtime mutation proves no reparse occurs), alongside the existing
`CostUsagePerformanceGateTests`.

## Invariants for future work

- Never let a window-width change invalidate per-file work: widen the retained
  window, don't reparse. Only a backward expansion beyond the retained window, a
  parser/pricing change, or an explicit force may reparse unchanged files.
- Any loop over session files drains an autoreleasepool per file.
- Session logs are streamed (`CostUsageJsonl.scan`) with a byte-level prefilter before
  any JSON parsing; never `readToEnd()` a session log — files reach hundreds of MB.
- Cache reads/writes are whole-file JSON today; keep them rare (dirty-tracked) or
  replace with a mapped/binary format before adding new per-refresh cache passes.
- New retained caches need a hard entry cap and an eviction path on memory pressure.
- `malloc_zone_pressure_relief` is best-effort cosmetics, not a budget tool. If
  footprint matters, measure `phys_footprint` high-water during the work itself.

## Known follow-ups

- Codex warm refresh still takes ~8 s on this machine (priority-turn trace scan plus
  incrementally parsing active rollout files). It is CPU/energy, not retained memory.
- Cold scans peak at ~200–350 MB transiently, dominated by `JSONSerialization`
  object graphs per candidate line. A field-extractor fast path (as Codex already
  has for some shapes) could cut this further.
- The models.dev pricing catalog (~1.6 MB JSON) is decoded whole and retained;
  pruning it to providers/models actually seen would trim steady-state live bytes.
