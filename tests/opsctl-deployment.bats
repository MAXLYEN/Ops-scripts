#!/usr/bin/env bats
# Isolated Python protocol tests; all filesystem changes use private temp dirs.

@test "opsctl runner: persistent jobs, real loopback APIs, authorization and rollback guards" {
  run env OPSCTL_BOOTSTRAP=/src/opsctl/bootstrap.py python3 -I /src/opsctl/tests/test_deployment.py
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "opsctl runner: legacy record verification remains explicitly metadata-only" {
  run env OPSCTL_BOOTSTRAP=/src/opsctl/bootstrap.py python3 -I /src/opsctl/tests/test_bootstrap.py
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
