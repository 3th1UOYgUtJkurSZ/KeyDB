# A fork child that crashes must run its crash handler to completion and exit.
#
# Regression test for a hang where the crash handler called bioKillThreads() in
# a fork child. The bio threads do not exist in the child (fork only clones the
# calling thread), so pthread_cancel()/pthread_join() on the inherited
# pthread_t either segfaults or blocks forever. The child then never exits, and
# it keeps every client/replica fd it inherited from the parent open, so those
# connections hang instead of being reset. It also does not answer SIGTERM,
# because the inherited handler only sets shutdown_asap and waits for an event
# loop that is not running in the child.

set system_name [string tolower [exec uname -s]]

# The crash handler only runs the memory test (and therefore killThreads()) when
# HAVE_PROC_MAPS is defined, which is Linux only.
if {$system_name eq {linux} && !$::valgrind} {

    proc process_is_alive {pid} {
        if {[catch {exec kill -0 $pid}]} {
            return 0
        }
        return 1
    }

    proc child_pids_of {pid} {
        if {[catch {exec pgrep -P $pid} out]} {
            # pgrep exits non-zero when there is no match
            return {}
        }
        return [split [string trim $out]]
    }

    start_server {tags {"repl external:skip"} overrides {use-fork yes crash-memcheck-enabled yes crash-log-enabled yes save {}}} {
        test "Crash handler in a fork child does not touch the parent's threads" {
            set ppid [s process_id]
            assert_equal {} [child_pids_of $ppid]
            set from_line [count_log_lines 0]

            r debug crash-in-fork-child 1
            catch {r bgsave}

            # Wait for the child to reach the end of its crash report.
            wait_for_log_messages 0 {"*FAST MEMORY TEST*"} $from_line 100 100

            # The child's crash handler must not run killThreads(): the bio and
            # server threads it would cancel/join do not exist in the child,
            # only their inherited pthread_t values do. Acting on those is
            # undefined behaviour -- on the glibc in production it segfaults
            # inside pthread_cancel() and then blocks forever in pthread_join(),
            # leaving the child alive with every inherited fd still open.
            set crashlog [exec tail -n +$from_line < [srv 0 stdout]]
            assert_equal 0 [regexp -- {Bio thread for job type} $crashlog]
            assert_equal 0 [regexp -- {main thread terminated} $crashlog]
        }

        test "Crashing fork child exits instead of hanging" {
            set ppid [s process_id]
            # The parent reaps the child from serverCron, so a child that ran
            # its crash handler to completion leaves the process table.
            wait_for_condition 100 100 {
                [llength [child_pids_of $ppid]] == 0
            } else {
                fail "fork child [child_pids_of $ppid] is still alive: it hung inside the crash handler"
            }
        }

        test "Parent survives a crashing fork child" {
            r debug crash-in-fork-child 0
            assert_equal {PONG} [r ping]
        }
    }

    # A crash arriving while the crash report is being written must not restart
    # the report. Re-running it repeats everything the first pass already did --
    # including killThreads(), which cannot survive being run twice: the second
    # pthread_join() targets a pthread_t that the first pass already joined.
    start_server {tags {"repl external:skip"} overrides {crash-memcheck-enabled yes crash-log-enabled yes save {}}} {
        test "Crash nested inside the crash report does not restart the report" {
            set stdout [srv 0 stdout]
            set from_line [count_log_lines 0]

            r debug crash-during-crash-report 1
            catch {r debug assert}

            wait_for_log_messages 0 {"*BUG REPORT END*"} $from_line 100 100
            wait_for_condition 100 100 {
                ![process_is_alive [srv 0 pid]]
            } else {
                fail "server is still alive after a nested crash"
            }

            set crashlog [exec tail -n +$from_line < $stdout]
            assert_equal 1 [regexp -all -- {DEBUG: FAULTING INSIDE THE CRASH REPORT} $crashlog]
            # The report body is written once, not once per crash. The nested
            # SIGSEGV still gets its own header and stack trace logged, which is
            # what tells us where it happened.
            assert_equal 1 [regexp -all -- {------ INFO OUTPUT ------} $crashlog]
            assert_equal 1 [regexp -all -- {crashed by signal} $crashlog]
        }
    }

    # Skipping killThreads() must stay scoped to fork children. In the parent
    # the threads are real, and stopping them is what makes the fast memory test
    # meaningful -- it needs the other threads to stop mutating memory.
    start_server {tags {"repl external:skip"} overrides {crash-memcheck-enabled yes crash-log-enabled yes save {}}} {
        test "Crash handler in the parent still stops the threads" {
            set from_line [count_log_lines 0]

            catch {r debug segfault}

            wait_for_log_messages 0 {"*FAST MEMORY TEST*"} $from_line 100 100
            set crashlog [exec tail -n +$from_line < [srv 0 stdout]]
            assert_equal 1 [regexp -- {Bio thread for job type} $crashlog]
        }
    }
}
