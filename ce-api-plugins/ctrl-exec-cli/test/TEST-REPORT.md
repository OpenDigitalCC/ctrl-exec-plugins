# Test report: ctrl-exec-cli (ce-api-plugins)
Generated: 2026-10-19T19:41:23Z

test/cli.t .. ok
All tests successful.
Files=1, Tests=18,  0 wallclock secs ( 0.01 usr  0.00 sys +  0.06 cusr  0.00 csys =  0.07 CPU)
Result: PASS

1..30
ok 1 a tick that runs a job exits 0
ok 2 a tick with nothing due exits 0 and says so
ok 3 a failing job is recorded and the tick still exits 0
ok 4 jobs still run when there is no syslog socket
ok 5 a day-of-week range matches weekdays only
ok 6 Sunday is both 0 and 7
ok 7 a step counts from the start of the field's range
ok 8 restricted day-of-month and day-of-week match either, as cron does
ok 9 lists and leading zeros match
ok 10 an invalid expression is reported with the field at fault
ok 11 a Sunday schedule written as 0 runs on Sunday
ok 12 an invalid schedule is logged, not silently ignored
ok 13 a .conf whose last line has no newline is still read
ok 14 a .conf with CRLF line endings is read
ok 15 keys other than schedule and runat are left to the job
ok 16 a minute between 5-minute ticks runs at the next tick
ok 17 a job runs once, not again at a repeated or early tick
ok 18 a minute that passed during an overrunning tick is caught up
ok 19 after more than an hour without a tick, missed minutes are not run
ok 20 a schedule that matches several minutes of one tick runs once
ok 21 runat runs at the first tick at or after it, never before
ok 22 runat on a tick boundary runs at that tick
ok 23 a runat that is not a date is logged
ok 24 explain names the jobs a real tick at the same time runs, and runs none
ok 25 explain shows the next ticks, and the minute an off-grid one is for
ok 26 explain shows where each runat stands
ok 27 explain reports problems and exits 1
ok 28 explain of a named job shows only that job
ok 29 explain skips a local time lost to daylight saving, as ticks do
ok 30 explain and the runner reject bad arguments with status 2

VERDICT: PASS
