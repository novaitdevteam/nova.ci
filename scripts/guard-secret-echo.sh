#!/usr/bin/env bash
#
# PreToolUse guard: refuse Bash commands that would print a secrets file verbatim.
#
# Reads the hook payload on stdin, looks at .tool_input.command, and exits 2 (block)
# when the command dumps a real `.env`. Exit 0 lets it through.
#
# What this does NOT cover, and must not be mistaken for:
#   - an editor `@.env` file reference. That pastes the file into the conversation
#     before any tool runs, so nothing here ever sees it. That is how the credentials
#     in this repository's .env reached a transcript on 2026-08-31.
#   - a secret arriving from any other source: a log line, an API response, a
#     screenshot, a paste.
# It stops one specific accident — an agent running `cat .env` — and nothing else.
# Treating it as broader coverage is the "guard that measures nothing" failure this
# repository keeps legislating against.
#
# Self-check: ./scripts/guard-secret-echo.sh --self-test
#
set -uo pipefail

# Dump verbs: they write file content to stdout, which lands in the transcript.
# Deliberately excludes `sed`/`awk`/`jq`, which are how a redacted read is done, and
# `.` / `source`, which load values without printing them.
#
# `open` and `pbcopy` were in this list and are not any more. Neither writes to stdout —
# one hands the file to a GUI editor, the other to the clipboard — so they were never the
# risk, and `open` collides with `open(...)` in Python and JavaScript. It blocked a
# heredoc that merely documented this guard. A false positive on a security check is not
# harmless: it trains people to reach for a bypass.
DUMP='cat|bat|head|tail|less|more|nl|xxd|od|strings'

# Match per segment, not per command. Two earlier versions of this got it wrong in
# opposite directions and both are worth remembering:
#
#   1. One regex spanning "verb ... path" mishandled word boundaries and let the most
#      obvious input — `cat .env` — straight through while catching `cat ./.env`.
#   2. Two independent conditions over the whole string over-blocked instead: any long
#      compound command that mentioned `.env` anywhere and used `tail` anywhere was
#      refused, including the one writing this comment.
#
# So: split on the operators that end a command, and require the verb and the path to be
# in the *same* segment. A false positive on a security check is not the safe side of the
# trade — it teaches people to route around the check.
#
# `.env.example` and friends fall out for free: the trailing class excludes `.`, so `.env`
# followed by another dot never matches.
is_blocked() { # is_blocked <command-string>
    local cmd="$1" seg
    # `;` `&&` `||` `|` and newlines end a command; substitute a NUL-free sentinel and split.
    while IFS= read -r seg; do
        [[ $seg =~ (^|[^[:alnum:]_-])(${DUMP})([^[:alnum:]_-]|$) ]] || continue
        [[ $seg =~ (^|[^[:alnum:]_.])\.env([^[:alnum:]_.]|$) ]] || continue
        return 0
    done < <(printf '%s\n' "$cmd" | sed -E 's/(\|\||&&|[;|&])/\n/g')
    return 1
}

if [ "${1:-}" = "--self-test" ]; then
    pass=0; fail=0
    check() { # check <expect:block|allow> <command>
        local want="$1" cmd="$2" got=allow
        is_blocked "$cmd" && got=block
        if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   [$want] $cmd"
        else fail=$((fail+1)); echo "FAIL [want $want, got $got] $cmd"; fi
    }
    check block 'cat .env'
    check block 'cat ./.env'
    check block 'head -20 .env'
    check block 'tail -n 5 /Users/x/repo/.env'
    check block 'ls && cat .env'
    check block 'less .env'
    check block 'xxd .env'
    # the redacted read this repository actually uses
    check allow "sed 's/=.*/=<redacted>/' .env"
    check allow 'set -a; . ./.env; set +a'
    check allow 'source .env && curl -H "Authorization: Bearer $outline_token" https://x'
    check allow 'cat .env.example'
    check allow 'cat .env.template'
    check allow 'cat README.md'
    check allow 'git check-ignore -v .env'
    check allow 'grep -c outline_token .env'
    # Regression: `open` used to be a dump verb, so any script that both called open()
    # and mentioned .env was blocked — including the one documenting this guard.
    check allow 'python3 -c "open(p).write(t)"  # mentions .env in a docstring'
    check allow 'node -e "fs.open(\".env.example\")"'
    # Prose about the guard is fine as long as it does not quote a dump command verbatim.
    check allow 'echo "the hook blocks commands that would dump a .env file"'
    # Known and accepted over-block: text that quotes an actual dump command is
    # indistinguishable from the command. This refused the commit message describing
    # this very guard. The workaround is to reword; narrowing the match to
    # command-position would let `sudo cat .env` and `xargs cat .env` through, which is
    # the worse trade.
    check block 'git commit -m "blocks an agent running cat .env by accident"'
    # Regression: verb and path in DIFFERENT segments. This exact shape — a heredoc
    # mentioning .env, then an unrelated `| tail -1` — blocked the commit that added
    # this rule to the documentation.
    check allow 'grep -c x .env > /dev/null && ./scripts/validate.sh | tail -1'
    check allow 'echo ".env" ; ls | head -3'
    # ...but the same verb and path together in one segment still must not pass.
    check block 'git status && cat .env | wc -l'
    check block 'echo hi; head .env'
    echo "--- $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
    exit
fi

payload="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

if is_blocked "$cmd"; then
    cat >&2 <<'MSG'
Blocked: this would print a secrets file into the transcript, where it cannot be recalled.

Read it without exposing values:
    sed 's/=.*/=<redacted>/' .env        # key names only
    set -a; . ./.env; set +a             # load into variables, print nothing

If you need a value, use it from the variable — never echo it. If one has already
reached the transcript, say so plainly and tell the user to rotate it.
MSG
    exit 2
fi
exit 0
