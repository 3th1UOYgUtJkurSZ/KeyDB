# The RDB writer used to assert that its expire counter matched the number of
# keys it actually saw carrying an expire:
#
#     serverAssert(ckeysExpired == db->expireSize());
#
# That count only feeds the RDB's RESIZEDB preallocation hint, so a drift does
# not make the RDB wrong -- but the assert made it fatal. In production a drift
# of +1 was enough to kill every BGSAVE, which killed replica full-sync, which
# took down the service. It must warn instead.
#
# Both bgsave shapes matter. use-fork yes loses only the child; use-fork no
# (what production runs now) does the save on a thread, so the assert would take
# the whole server down.

proc process_is_alive {pid} {
    if {[catch {exec kill -0 $pid}]} { return 0 }
    return 1
}

foreach forkmode {yes no} {
    # use-fork is IMMUTABLE_CONFIG, so it has to be set at startup.
    start_server [list tags {"repl external:skip"} \
                  overrides [list use-fork $forkmode crash-log-enabled yes \
                                  crash-memcheck-enabled yes save {} appendonly no]] {

        test "BGSAVE survives a drifted expire count (use-fork $forkmode)" {
            assert_equal $forkmode [lindex [r config get use-fork] 1]

            r set k1 v
            r expire k1 3600
            r set k2 v
            set from_line [count_log_lines 0]

            # Skew the counter the way production did: expireSize() ends up
            # larger than the number of keys that really carry an expire.
            r debug corrupt-expires-count 5
            assert_equal {6 1} [r debug expires-consistency]

            r bgsave
            waitForBgsave r

            assert_equal {PONG} [r ping]
            assert_equal 1 [process_is_alive [srv 0 pid]]
            wait_for_log_messages 0 {"*Expire count mismatch*"} $from_line 50 100
        }

        test "the RDB written with a drifted count is still loadable (use-fork $forkmode)" {
            # The drift must not corrupt the dump: the count is only a hint.
            assert_equal {OK} [r debug reload]
            assert_equal {v} [r get k1]
            assert_equal {v} [r get k2]
            assert {[r ttl k1] > 0}
        }

        test "reload rebuilds a correct expire count (use-fork $forkmode)" {
            # Loading counts expires from scratch, so the invariant holds again.
            set res [r debug expires-consistency]
            assert_equal [lindex $res 0] [lindex $res 1]
        }
    }
}
