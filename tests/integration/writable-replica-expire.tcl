# Keys given a TTL directly on a writable replica are tracked in
# slaveKeysWithExpire, because the master will never send a DEL for them. The
# replica expires them itself from expireSlaveKeys(), via databasesCron().
#
# That loop used to reach through its iterator again after expiring the key:
#
#     if (itrDB != db->end() && itrDB->FExpires()) {
#         if (itrDB->expire.when() < start)
#             expired = activeExpireCycleExpire(...);   // frees the robj
#     }
#     if (itrDB != db->end() && itrDB->FExpires() && !expired) {   // use-after-free
#
# activeExpireCycleExpire() deletes the key, so the robj behind itrDB is gone by
# the time FExpires() is called on it again. Upstream Redis holds a dictEntry*
# from db->expires here and only tests it for NULL after expiring -- it never
# dereferences it. KeyDB moved the expire into the robj, and the second check
# became a dereference of freed memory.
#
# It segfaults inside databasesCron(), which is how it showed up as a flaky
# integration/replication-3.

start_server {tags {"repl external:skip"}} {
    set master [srv 0 client]
    set master_host [srv 0 host]
    set master_port [srv 0 port]

    start_server {tags {"repl external:skip"}} {
        set replica [srv 0 client]
        set replica_stdout [srv 0 stdout]

        # A writable replica is what makes the replica track and expire these
        # keys on its own.
        $replica config set replica-read-only no
        $replica slaveof $master_host $master_port
        wait_for_condition 50 200 {
            [string match "*master_link_status:up*" [$replica info replication]]
        } else {
            fail "replica never linked up"
        }

        test "writable replica expires its own keys without crashing" {
            # Short TTLs so expireSlaveKeys() does the deleting, and enough keys
            # that the freed objects get reused -- which is what turns the
            # use-after-free into a segfault.
            for {set round 0} {$round < 6} {incr round} {
                for {set i 0} {$i < 200} {incr i} {
                    $replica set rk:$round:$i [string repeat x 64]
                    $replica pexpire rk:$round:$i 150
                }
                # Churn while they expire, so the allocator hands the freed
                # robjs straight back out.
                for {set i 0} {$i < 200} {incr i} {
                    $replica set filler:$round:$i [string repeat y 64]
                }
                after 400
                assert_equal {PONG} [$replica ping]
            }

            assert_equal 0 [count_message_lines $replica_stdout "crashed by signal"]
            assert_equal 0 [count_message_lines $replica_stdout "ASSERTION FAILED"]
        }

        test "those keys are actually gone and the replica is still consistent" {
            wait_for_condition 50 200 {
                [$replica dbsize] > 0
            } else {
                fail "replica lost everything"
            }
            for {set i 0} {$i < 200} {incr i} {
                assert_equal 0 [$replica exists rk:0:$i]
            }
            assert_equal 1 [$replica exists filler:0:0]
            assert_equal {PONG} [$replica ping]
        }

        test "replica keeps taking replicated writes afterwards" {
            $master set from-master ok
            wait_for_condition 50 200 {
                [$replica get from-master] eq {ok}
            } else {
                fail "replication stopped working"
            }
        }
    }
}
