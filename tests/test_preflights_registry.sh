#!/bin/bash
# tests/test_preflights_registry.sh — preflight registry unit tests.
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_preflights_registry"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/preflights.sh"

# Fresh registry state per test
cl_pf_registry_reset

# Register two fake preflights
_fake_pf_a() { return 0; }
_fake_pf_b() { return 1; }
cl_pf_register 1 "label A" _fake_pf_a
cl_pf_register 2 "label B" _fake_pf_b

# Listing preflights in slot order
got=$(cl_pf_list_labels)
assert_eq "$got" "label A
label B" "list labels in slot order"

# Lookup label by slot
got=$(cl_pf_label_for 1); assert_eq "$got" "label A" "label_for slot 1"
got=$(cl_pf_label_for 2); assert_eq "$got" "label B" "label_for slot 2"

# Passed accumulator starts empty
got=$(cl_pf_passed_labels); assert_eq "$got" "" "passed starts empty"

# Running the registry marks passed slots and aborts on first failure.
# NOTE: call cl_pf_run_all directly (not via $(...) command substitution) so
# modifications to CL_PF_PASSED survive into the rest of the test.
cl_pf_run_all; rc=$?
assert_nonzero "$rc" "run_all returns nonzero when a preflight fails"

# After the run, slot 1 is in 'passed' but slot 2 is not
got=$(cl_pf_passed_labels); assert_eq "$got" "label A" "only slot 1 recorded as passed"

# Autoregistration: sourcing with CL_PF_AUTOREGISTER=1 registers pf_1 by slot/label
cl_pf_registry_reset
CL_PF_AUTOREGISTER=1 . "$CL_DIR/lib/preflights.sh"
got=$(cl_pf_label_for 1)
assert_eq "$got" "macOS + iTerm2 + not in tmux" "pf_1 registered with correct label"
unset CL_PF_AUTOREGISTER

test_summary
