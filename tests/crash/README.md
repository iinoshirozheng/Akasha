# Crash tests

Run the recovery harness with:

```bash
pixi run test-crash
```

`test_wal_tail.mojo` persists one valid mutation, appends an incomplete next
record to simulate a torn write, reopens the collection, writes again, and
reopens a second time. This verifies that recovery both ignores and durably
removes the torn tail before allowing another append.

The manifest and segment unit tests separately exercise temp-file publication,
atomic replacement, missing referenced segments, checksums, and truncation.
