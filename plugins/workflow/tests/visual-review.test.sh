#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(cd "$(dirname "$0")" && pwd)
node --test "$TEST_ROOT/visual-review.test.cjs"
