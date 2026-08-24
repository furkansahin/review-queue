#!/usr/bin/env bash
# Injection tests for the forced-command wrapper.
#
#   bash devbox/test_wrapper.sh [wrapper-path]
#
# The wrapper is only reached by RQ_TRANSPORT=ssh now; the dashboard runs bay
# itself. It is still worth holding, because it is the thing a key could reach.
#
# It builds its own fixtures. They used to live in a scratchpad outside the
# repository, so when that was cleaned the test stopped running -- and the
# failure looked like the wrapper, not the fixtures.
W="${1:-$(cd "$(dirname "$0")" && pwd)/rq-review}"
SP="$(mktemp -d)"
trap 'rm -rf "$SP"' EXIT

mkdir -p "$SP/fakebay" "$SP/fakerepo" "$SP/rqstate" "$SP/fakecfg"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SP/fakebay/bay"
chmod +x "$SP/fakebay/bay"
# ping checks for bay.toml specifically, so the fixture needs both.
printf '[commands]\nreview = "x"\n' > "$SP/fakecfg/bay.toml"
printf '[commands]\nreview = "x"\n\n[box]\nbaseImage = "y"\n' > "$SP/fakecfg/bay.local.toml"
: > "$SP/empty.md"
# The wrapper refuses to review without its prompt, so give it one.
printf 'run the specs that cover the change\n' > "$SP/prompt.md"

export RQ_BAY="$SP/fakebay/bay" RQ_REPO_PATH="$SP/fakerepo" RQ_STATE_DIR="$SP/rqstate"
export RQ_ALLOWED_REPOS="ubicloud/ubicloud"
export RQ_BAY_CONFIG="$SP/fakecfg"
export RQ_REVIEW_PROMPT="$SP/prompt.md"
fail=0
try() { # name, command, expect: allow|refuse
  local name="$1" cmd="$2" expect="$3"
  rm -f /tmp/rq_pwned
  out=$(SSH_ORIGINAL_COMMAND="$cmd" bash "$W" 2>&1); rc=$?
  local got="allow"; [ $rc -ne 0 ] && got="refuse"
  local pwned=""; [ -f /tmp/rq_pwned ] && pwned=" !!! EXECUTED INJECTED COMMAND"
  if [ "$got" = "$expect" ] && [ -z "$pwned" ]; then
    printf "  ok    %-46s %s\n" "$name" "$got"
  else
    printf "  FAIL  %-46s got=%s want=%s%s\n" "$name" "$got" "$expect" "$pwned"; fail=$((fail+1))
  fi
}
try "ping works"                    "ping"                                          allow
try "unknown verb refused"          "shell"                                         refuse
try "empty command refused"         ""                                              refuse
try "bare bash refused"             "bash -i"                                       refuse
try "valid review accepted"         "review ubicloud/ubicloud 6172 rq-ubicloud-6172" allow
try "repo not on allowlist refused" "review evil/repo 1 rq-x-1"                     refuse
try "semicolon in box refused"      "review ubicloud/ubicloud 1 box;touch /tmp/rq_pwned" refuse
try "command substitution refused"  'review ubicloud/ubicloud 1 $(touch /tmp/rq_pwned)'  refuse
try "backtick refused"              'review ubicloud/ubicloud 1 `touch /tmp/rq_pwned`'   refuse
try "pipe in repo refused"          "review ubicloud/ubicloud|sh 1 b"               refuse
try "non-numeric pr refused"        "review ubicloud/ubicloud 1abc rq-x-1"          refuse
try "negative pr refused"           "review ubicloud/ubicloud -1 rq-x-1"            refuse
try "path traversal repo refused"   "review ../../etc/passwd 1 rq-x-1"              refuse
try "uppercase box refused"         "review ubicloud/ubicloud 1 RQ-X"               refuse
try "overlong box refused"          "review ubicloud/ubicloud 1 $(printf 'a%.0s' {1..60})" refuse
try "status ok"                     "status rq-ubicloud-6172"                       allow
try "status bad box refused"        "status ../etc"                                 refuse
try "result ok"                     "result rq-ubicloud-6172"                       allow

# The verbs below had no test before: ask, build, list, teardown, and arity.
try "extra argument refused"        "review ubicloud/ubicloud 1 rq-x-1 JUNK"        refuse
try "too few arguments refused"     "review ubicloud/ubicloud 1"                    refuse
try "status needs a box"            "status"                                        refuse
try "status extra arg refused"      "status rq-x-1 JUNK"                            refuse
try "teardown needs a box"          "teardown"                                      refuse
try "teardown extra arg refused"    "teardown rq-x-1 JUNK"                          refuse
try "build bad box refused"         "build ../etc"                                  refuse
try "build ok"                      "build rq-x-1"                                  allow
try "list takes no box"             "list"                                          allow
try "ask needs a box"               "ask"                                           refuse
try "ask bad box refused"           "ask ../etc"                                    refuse
try "result extra arg refused"      "result rq-x-1 JUNK"                            refuse
try "build extra arg refused"       "build rq-x-1 JUNK"                             refuse
try "skills needs a value"          "skills"                                        refuse
try "skills rejects another host"   "skills https://gitlab.com/a/b"                 refuse
try "skills rejects ssh form"       "skills git@github.com:a/b.git"                 refuse
try "skills rejects a metachar"     "skills https://github.com/a/b;id"              refuse
try "skills rejects extra args"     "skills https://github.com/a/b x"               refuse
try "skills accepts a github url"   "skills https://github.com/a/b"                 allow
try "skills accepts - to clear"     "skills -"                                      allow
# A missing prompt must stop the review here, not reach claude as an empty
# argument. That is exactly how the follow-up used to fail.
out=$(RQ_REVIEW_PROMPT="$SP/does-not-exist.md" SSH_ORIGINAL_COMMAND="review ubicloud/ubicloud 1 rq-x-1" bash "$W" 2>&1)
if [ $? -ne 0 ] && [[ "$out" == *"review prompt missing"* ]]; then
  printf "  ok    %-46s %s\n" "missing prompt refused, with a reason" "refuse"
else
  printf "  FAIL  %-46s %s\n" "missing prompt refused, with a reason" "got=$out"; fail=$((fail+1))
fi
out=$(RQ_REVIEW_PROMPT="$SP/empty.md" SSH_ORIGINAL_COMMAND="review ubicloud/ubicloud 1 rq-x-1" bash "$W" 2>&1)
if [ $? -ne 0 ]; then
  printf "  ok    %-46s %s\n" "empty prompt refused too" "refuse"
else
  printf "  FAIL  %-46s %s\n" "empty prompt refused too" "allowed"; fail=$((fail+1))
fi

echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "$fail FAILURE(S)"
exit $fail
