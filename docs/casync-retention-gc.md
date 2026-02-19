# casync Retention and GC Plan

This plan keeps compose history traceable while safely reclaiming unreachable chunk data.

## Protection policy

Protect these objects from deletion:

- All `live-pocket-fedora/casync/refs/*/latest.json` pointers.
- All manifests and indexes referenced by protected pointers.
- All manifests and indexes newer than 30 days.
- At least the newest 20 manifests per ref, even if older than 30 days.
- Any manifest/index explicitly pinned for release or incident response.

## Safe pruning workflow

1. Build keep-set:
   - enumerate `refs/*/latest.json`
   - add time-window and per-ref count protections
   - resolve protected manifest/index object keys
2. Download protected indexes to a local workspace.
3. Mirror chunk metadata locally (or mirror full chunk store if required by tooling).
4. Run dry-run reachability analysis with casync:
   - `casync gc --dry-run --store=<local-store> <protected-index-1> ...`
5. Review candidate removals and ensure no protected refs/manifests are affected.
6. Delete unreachable chunks in batch from object storage.
7. Re-run dry-run GC; expect zero or minimal candidates after cleanup.

## Operational safeguards

- Never delete manifests/indexes and chunks in the same step.
- Use a two-phase process:
  - phase 1: delete obsolete manifests/indexes
  - phase 2 (later): prune unreachable chunks
- Keep a rollback export (object key list + manifest snapshots) before phase 2.
- Run GC from a trusted branch with manual approval.

## Suggested cadence

- Daily: pointer refresh from CI builds.
- Weekly: dry-run GC report artifact.
- Monthly: approved delete pass for unreachable chunks.

## Failure recovery

- If a chunk needed by a kept index was deleted, regenerate by rebuilding that commit and republishing with compose publish enabled.
- If lineage pointers are stale/corrupt, restore from manifest history and rewrite `refs/<ref>/latest.json`.
