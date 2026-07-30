# A redisMaster that somehow ends up with both master and cached_master set must
# not take the server down when the link drops.
#
# replicationCacheMaster() used to assert on that combination:
#
#     serverAssert(mi->master != NULL && mi->cached_master == NULL);
#
# and updateActiveReplicaMastersFromRsi() produced it routinely: after a full
# resync it cached a master for every RDB entry whose redisMaster had no master
# client attached, and the master being synced from has not installed its client
# yet at that point. Entries are matched by masterhost:masterport, and when peers
# are reached through local tunnel ports every node's master list is textually
# identical, so that entry reliably found a match. Every node in the affected
# cluster died on this repeatedly.
#
# The root cause is fixed in updateActiveReplicaMastersFromRsi() (it now skips the
# master it is syncing from). This test covers the second half of the fix: even if
# a stale cached master shows up some other way, dropping the link must discard it
# and carry on rather than kill the process. DEBUG PLANT-STALE-CACHED-MASTER
# recreates the state directly, which is stable to drive -- reproducing it through
# a real resync needs the tunnel topology described above.

start_server {tags {"active-repl external:skip"} overrides {active-replica yes multi-master yes}} {
    set B [srv 0 client]
    set B_host [srv 0 host]
    set B_port [srv 0 port]

    start_server {tags {"active-repl external:skip"} overrides {active-replica yes multi-master yes}} {
        set A [srv 0 client]
        set A_stdout [srv 0 stdout]

        test "active replica links up with its master" {
            for {set i 0} {$i < 50} {incr i} { $B set k$i v$i }
            $A slaveof $B_host $B_port
            wait_for_condition 100 200 {
                [string match "*master_link_status:up*" [$A info replication]]
            } else {
                fail "A never linked up with B"
            }
            wait_for_ofs_sync $A $B
            assert_equal {v0} [$A get k0]
        }

        test "a link drop with a stale cached master does not kill the server" {
            assert_equal 1 [$A debug plant-stale-cached-master]

            # Before the fix this hit the assert in replicationCacheMaster().
            catch {$A client kill type master}
            after 300

            assert_equal {PONG} [$A ping]
            assert_equal 0 [count_message_lines $A_stdout "ASSERTION FAILED"]
            assert {[count_message_lines $A_stdout "stale cached master"] >= 1}
        }

        test "the link recovers and replication still works after that" {
            wait_for_condition 100 200 {
                [string match "*master_link_status:up*" [$A info replication]]
            } else {
                fail "A did not re-establish its master link"
            }
            # Not comparing offsets: the injected cached master carries a replid
            # it never earned, so A's PSYNC bookkeeping is deliberately odd here.
            # What matters is that data keeps flowing.
            $B set after-recovery yes
            wait_for_condition 100 200 {
                [$A get after-recovery] eq {yes}
            } else {
                fail "replication did not resume after the stale cached master"
            }
        }

        test "repeated drops with stale cached masters stay survivable" {
            for {set round 0} {$round < 5} {incr round} {
                catch {$A debug plant-stale-cached-master}
                catch {$A client kill type master}
                after 250
                assert_equal {PONG} [$A ping]
            }
            assert_equal 0 [count_message_lines $A_stdout "ASSERTION FAILED"]
        }
    }
}
