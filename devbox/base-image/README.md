# Prebaked base image

## The problem, measured

On a 2-vcpu Ubicloud VM, `bay up` took:

| | |
| --- | --- |
| first box, cold machine | 335s |
| second box, warm machine | 329s |
| box from a pull request | 319s |

A warm machine saved nothing, because the work happens **inside each fresh
container**, not on the host.

## Where it goes

`ubicloud/ubicloud`'s `mise.toml` sets:

```toml
[settings]
ruby.compile = true
```

so every container compiles Ruby 4.0.5 from source. Then `bundle install` fetches
203 gems and `npm ci` runs, all per box.

## Two fixes, in order of value

**1. Stop compiling Ruby.** Measured on the same machine: **329s -> 144s**, from
one line. Either drop `ruby.compile = true` from the repo's `mise.toml`, or set
`MISE_RUBY_COMPILE=0` in `box.env` to keep it local to dev boxes.

**2. Bake the toolchain and gems into a base image** — the `Dockerfile` here.

```sh
docker build -t ubicloud-bay-base:latest devbox/base-image
```

```toml
# bay.toml
[box]
baseImage = "ubicloud-bay-base:latest"
```

bay's own Dockerfile is `ARG BASE_IMAGE`, so it layers its sshd/tmux setup on
top and finds the toolchain already present.

## What no image can remove

Each box runs its own Postgres and applies the full migration history to it.
That is inherent to one-database-per-box, and it is a real part of what remains
after the toolchain is baked.

## A shared volume is not the answer

Mounting one `bay-shared-mise` volume across boxes was measured at **151s warm
against 144s cold** — no benefit. The gems and toolchain need to be in the image,
not in a volume that still has to be resolved per box.
