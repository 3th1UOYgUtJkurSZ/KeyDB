# An async flush must clear the same state the synchronous one does.
#
# redisDbPersistentData::clear() resets m_pdict, m_pdictTombstone, m_pdbSnapshot,
# m_dictChanged and m_numexpires. emptyDbAsync() only swapped m_pdict and reset
# m_numexpires -- it left m_pdbSnapshot pointing at the snapshot and left the old
# tombstones in place.
#
# With a snapshot still attached, ensure() happily materializes keys back out of
# it, so keys the flush was supposed to remove reappear on the next lookup.
#
# DEBUG SNAPSHOT-HOLD keeps a snapshot open so this is deterministic rather than
# racing the snapshot that KEYS, an async read, or a threaded bgsave would make.

start_server {tags {"repl external:skip"} overrides {use-fork no save {} appendonly no maxmemory-policy noeviction}} {

    test "FLUSHALL ASYNC empties the db when no snapshot is attached" {
        r flushall
        r set k1 v1
        r set k2 v2
        r expire k1 3600

        r flushall async

        assert_equal 0 [r dbsize]
        assert_equal {} [r get k1]
        assert_equal {} [r get k2]
        assert_equal {0 0} [r debug expires-consistency]
    }

    test "FLUSHALL ASYNC empties the db while a snapshot is held" {
        r flushall
        r set k1 v1
        r set k2 v2
        r expire k1 3600
        assert_equal {1 1} [r debug expires-consistency]

        r debug snapshot-hold 1
        r flushall async

        # Before the fix the snapshot was still attached, so these lookups went
        # through ensure() and brought the flushed keys back to life.
        assert_equal {} [r get k1]
        assert_equal {} [r get k2]
        assert_equal 0 [r dbsize]
        assert_equal {0 0} [r debug expires-consistency]

        r debug snapshot-hold 0

        assert_equal {} [r get k1]
        assert_equal {} [r get k2]
        assert_equal 0 [r dbsize]
        assert_equal {0 0} [r debug expires-consistency]
        assert_equal {PONG} [r ping]
    }

    test "FLUSHDB ASYNC under a snapshot does not resurrect keys either" {
        r flushall
        for {set i 0} {$i < 100} {incr i} {
            r set key:$i v
            if {$i % 2 == 0} { r expire key:$i 3600 }
        }
        assert_equal {50 50} [r debug expires-consistency]

        r debug snapshot-hold 1
        r flushdb async

        assert_equal 0 [r dbsize]
        for {set i 0} {$i < 100} {incr i} {
            assert_equal {} [r get key:$i]
        }
        assert_equal {0 0} [r debug expires-consistency]

        r debug snapshot-hold 0
        assert_equal 0 [r dbsize]
        assert_equal {0 0} [r debug expires-consistency]
    }

    test "writes after an async flush under a snapshot stay consistent" {
        r flushall
        r set old v
        r expire old 3600

        r debug snapshot-hold 1
        r flushall async

        # Reusing a flushed key name must behave like a fresh insert.
        r set old newv
        assert_equal {newv} [r get old]
        assert_equal {0 0} [r debug expires-consistency]

        r set fresh v
        r expire fresh 3600
        assert_equal {1 1} [r debug expires-consistency]

        r debug snapshot-hold 0
        assert_equal {1 1} [r debug expires-consistency]
        assert_equal 2 [r dbsize]
    }

    test "BGSAVE after an async flush under a snapshot reports no mismatch" {
        set from_line [count_log_lines 0]
        r bgsave
        waitForBgsave r
        assert_equal 0 [count_message_lines [srv 0 stdout] "Expire count mismatch"]
        assert_equal {OK} [r debug reload]
        assert_equal {1 1} [r debug expires-consistency]
    }
}
