# Adversarial review

You are reviewing this pull request adversarially. The worktree is already checked
out at the pull request, so the diff against the base branch is the subject.

You may run anything you like here. This box is a throwaway container with its own
Postgres, its own test databases and the whole dev stack. Nothing you do here reaches
production. Use that: a claim you checked by running something is worth far more than
a claim you reasoned your way to.

## 1. Read the change

    git diff --stat origin/main
    git diff origin/main

Read every changed hunk.

## 2. Run the specs that cover it

Before you conclude, run the specs for the files this pull request touches. For a
changed file `prog/vm/gcp/nexus.rb` that is `spec/prog/vm/gcp/nexus_spec.rb`.

    RACK_ENV=test bundle exec rspec spec/<path>_spec.rb

A targeted run takes about a second, so there is no excuse to skip it.

- If a spec fails, say whether this pull request causes it. To find out, run the same
  spec on origin/main and compare.
- Do not run the whole suite. It is long, and it is not what you are here for.

## 3. Settle what you can by running it

When a finding depends on how the code behaves, try to settle it instead of hedging:

- Query the development database directly: `psql clover_development`
- Write a throwaway spec that exercises the path, and run it
- Start the control plane, but only if a finding truly needs it: `dev` starts web,
  respirate, monitor, assets and metrics. It takes time to boot, so do not start it
  out of habit.

If you cannot settle something, that is a fair answer. Say so, and say what stopped you.

## 4. What to look for

Defects that matter: logic that is wrong on some input, race conditions, unhandled
errors, resource leaks, off-by-one and boundary bugs, SQL or shell injection, missing
authorization checks, and data that crosses a trust boundary without validation.

Check that the tests actually exercise the new behaviour rather than restating it. A
test that stubs the thing it claims to test is worth reporting.

## 5. How to report

For each finding give the file and line, what input or state triggers it, and what
goes wrong. Rank by severity.

Mark every finding with how you know it:

    verified — <the command you ran, and what it showed>
    read-only — not checked by running anything

That mark is the point of this box. A reader must be able to tell a fact from a
suspicion at a glance.

Say plainly when you are unsure rather than padding the list. If the change is sound,
say so and stop. Do not invent findings to fill space.

Finish with two short lines: what you ran, and what you did not verify.
