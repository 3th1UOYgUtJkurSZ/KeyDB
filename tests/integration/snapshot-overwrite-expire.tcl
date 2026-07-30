# Overwriting a key that currently lives only in a snapshot must still go through
# the overwrite path.
#
# genericSetKey() calls prepOverwriteForSnapshot() first, which plants a tombstone
# for the key. ensure() then sees that tombstone and skips materializing the key
# from the snapshot, so the dictAdd() in insert() SUCCEEDS -- dbAddCore() reports
# "inserted", and dbOverwrite() (and with it removeExpire()) is never called.
#
# createSnapshot() hands the whole main dict to the snapshot and leaves the live
# db with an empty one, so while a snapshot is held EVERY key is snapshot-only.
# Two things then go wrong for a key that carries an expire:
#   1. the expire is still counted in expireSize(), but no key carries it any
#      more -- the drift that makes the RDB writer complain
#   2. SET ... KEEPTTL silently loses the TTL, because the old value is never
#      looked at
#
# DEBUG SNAPSHOT-HOLD keeps a snapshot open so this is deterministic instead of
# racing the snapshot that KEYS or an async read would create.

start_server {tags {"repl external:skip"} overrides {use-fork no save {} appendonly no maxmemory-policy noeviction}} {

    test "SET over an expiring key drops the TTL and the count (no snapshot)" {
        r flushall
        r set k v
        r expire k 3600
        assert_equal {1 1} [r debug expires-consistency]

        r set k v2

        assert_equal -1 [r ttl k]
        assert_equal {0 0} [r debug expires-consistency]
    }

    test "SET KEEPTTL over an expiring key keeps the TTL (no snapshot)" {
        r flushall
        r set k v
        r expire k 3600
        r set k v2 keepttl
        assert_range [r ttl k] 3500 3600
        assert_equal {1 1} [r debug expires-consistency]
    }

    test "SET over a snapshot-only expiring key still drops the count" {
        r flushall
        r set k v
        r expire k 3600
        assert_equal {1 1} [r debug expires-consistency]

        r debug snapshot-hold 1
        r set k v2
        r debug snapshot-hold 0

        assert_equal -1 [r ttl k]
        # Before the fix this reported {1 0}: the expire was still counted even
        # though no key carried it.
        assert_equal {0 0} [r debug expires-consistency]
    }

    test "SET KEEPTTL over a snapshot-only key keeps the TTL" {
        r flushall
        r set k v
        r expire k 3600

        r debug snapshot-hold 1
        r set k v2 keepttl
        r debug snapshot-hold 0

        # Before the fix the TTL was silently lost (ttl == -1).
        assert_range [r ttl k] 3500 3600
        assert_equal {1 1} [r debug expires-consistency]
        assert_equal {v2} [r get k]
    }

    test "count stays correct overwriting many snapshot-only expiring keys" {
        r flushall
        for {set i 0} {$i < 500} {incr i} {
            r set key:$i v
            r expire key:$i 3600
        }
        assert_equal {500 500} [r debug expires-consistency]

        r debug snapshot-hold 1
        for {set i 0} {$i < 500} {incr i} {
            r set key:$i v2
        }
        r debug snapshot-hold 0

        # Before the fix: {500 0}.
        assert_equal {0 0} [r debug expires-consistency]
    }

    test "BGSAVE reports no expire mismatch after snapshot overwrites" {
        set from_line [count_log_lines 0]
        r bgsave
        waitForBgsave r
        assert_equal 0 [count_message_lines [srv 0 stdout] "Expire count mismatch"]
        assert_equal {PONG} [r ping]
    }
}
