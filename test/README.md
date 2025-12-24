Injector Integration Tests
==========================

This directory contains integration tests for the injector code.
The tests in this folder do not use a multi-platform image; instead, an injector binary is build (in a container)
per CPU architecture, and then used for testing.
Note that the Zig source code in `src` also contains Zig unit tests.

The available test cases for the injector integration tests are listed in the files
`test/scripts/*.tests`.

Usage
-----

* `scripts/test-all.sh` to run all tests.
* `ARCHITECTURES=arm64,amd64 scripts/test-all.sh` to run tests for a subset of CPU architectures.
  Can be combined with `LIBC_FLAVORS` and other flags.
* `LIBC_FLAVORS=glibc,musl scripts/test-all.sh` to run tests for a subset of libc flavors.
  Can be combined with `ARCHITECTURES` and other flags.
* `TEST_SETS=default,node_js,jvm,sdk-does-not-exist,sdk-cannot-be-accessed` to only run a subset of test sets. The test
   set names are the different `scripts/*.tests` files. Can be combined with `ARCHITECTURES`, `LIBC_FLAVORS` etc.
* `TEST_CASES="overrides NODE_OPTIONS if it is not present" scripts/test-all.sh` to only run test cases whose
  names _exactly match_ one of the provided strings.
  The test cases are listed in the different test sets, i.e. the `scripts/*.tests` files.
  Can be combined with `ARCHITECTURES`, `LIBC_FLAVORS` etc., cannot be combined with `TEST_CASES_CONTAINING`.
* `TEST_CASES_CONTAINING=OTEL_RESOURCE_ATTRIBUTES,OTEL_RESOURCE_ATTRIBUTES scripts/test-all.sh` to only run tests cases
  whose names _contain_ one of the provided strings as a substring.
  The test cases are listed in the different `scripts/*.tests` files.
  Can be combined with `ARCHITECTURES`, `LIBC_FLAVORS` etc., cannot be combined with `TEST_CASES`.
* Set `VERBOSE=true` to set `OTEL_INJECTOR_LOG_LEVEL=debug` when running test cases and to always include the output
  from running the test case. Otherwise, the default log level (`error`) is used, and output is only printed to stdout
  when a test case fails.
* Set `INTERACTIVE=true` to get a shell into the container under test, instead of running a test. Best used when working
  on a test for one specific runtime, you would usually want to combine this with something like
  `ARCHITECTURES=arm64 LIBC_FLAVORS=glibc TEST_SETS=dotnet INTERACTIVE=true scripts/test-all.sh` to narrow down the
  scope to one container under test.
