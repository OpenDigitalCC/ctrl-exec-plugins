# Test report: ctrl-exec-cli (ce-api-plugins)
Generated: 2026-10-21T07:45:54Z

test/cli.t ........ ok
test/hint.t ....... ok
test/input.t ...... ok
test/transport.t .. ok
All tests successful.
Files=4, Tests=188,  4 wallclock secs ( 0.04 usr  0.00 sys +  3.06 cusr  0.92 csys =  4.02 CPU)
Result: PASS

1..32
ok 1 a tick that runs a job exits 0
ok 2 a tick with nothing due exits 0 and says so
ok 3 a failing job is recorded and the tick still exits 0
ok 4 logging goes to the named syslog socket
ok 5 with no syslog socket, log lines go to stderr
ok 6 jobs still run when logger fails
ok 7 a day-of-week range matches weekdays only
ok 8 Sunday is both 0 and 7
ok 9 a step counts from the start of the field's range
ok 10 restricted day-of-month and day-of-week match either, as cron does
ok 11 lists and leading zeros match
ok 12 an invalid expression is reported with the field at fault
ok 13 a Sunday schedule written as 0 runs on Sunday
ok 14 an invalid schedule is logged, not silently ignored
ok 15 a .conf whose last line has no newline is still read
ok 16 a .conf with CRLF line endings is read
ok 17 keys other than schedule and runat are left to the job
ok 18 a minute between 5-minute ticks runs at the next tick
ok 19 a job runs once, not again at a repeated or early tick
ok 20 a minute that passed during an overrunning tick is caught up
ok 21 after more than an hour without a tick, missed minutes are not run
ok 22 a schedule that matches several minutes of one tick runs once
ok 23 runat runs at the first tick at or after it, never before
ok 24 runat on a tick boundary runs at that tick
ok 25 a runat that is not a date is logged
ok 26 explain names the jobs a real tick at the same time runs, and runs none
ok 27 explain shows the next ticks, and the minute an off-grid one is for
ok 28 explain shows where each runat stands
ok 29 explain reports problems and exits 1
ok 30 explain of a named job shows only that job
ok 31 explain skips a local time lost to daylight saving, as ticks do
ok 32 explain and the runner reject bad arguments with status 2

VERDICT: PASS
