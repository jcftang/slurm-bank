# Tests

The repository has two complementary test modes:

* `make -C t functional` runs deterministic functional tests with fake Slurm
  command-line tools. It does not require a Slurm controller, SlurmDBD, root
  privileges, or an accounting database.
* `make test` keeps the original live integration test path. Those tests expect
  Slurm commands and, for some cases, privileged access to a real test cluster.

The functional suite exercises the public `sbank` command and its subcommands,
checks the exact `sacctmgr`/`scontrol`/`sinfo`/`sacct`/`sbatch` calls emitted by
mutating operations, and directly exercises the Perl balance and CPU-capacity
helpers with deterministic command output.

`_sbank-common-cpu_hrs.pl` depends on the Perl `Switch` module. The functional
suite skips only that helper's assertions if `Switch` is unavailable; CI
installs the module so those paths are always tested there.

## Continuous integration

See [the CI guide](../doc/ci.mdwn) for required mock/source/package checks and
the separate disposable Slurm integration workflow. The `functional` and
`functional-gpu` targets never use a real cluster. `SBANK_TEST_SOURCE` can select
an installed bin directory for those suites. Their temporary helper shims do
not modify that directory; installation CI also invokes its entry point directly.
