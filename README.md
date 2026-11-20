# Rust for Mavericks

Rust toolchain for Mac OS X 10.9 Mavericks.

Included:

- `cargo` (and `cargo clippy` and `cargo fmt`)
- `rustdoc`

## Compiling

### Directly on Mavericks

Install [clang22](https://github.com/Mavergreen/clang-22/releases/latest) first, with the 10.9 SDK it
needs from [Longboat](https://github.com/Mavergreen/longboat/releases/latest): rust links with clang22
by default, so you don't need Apple's Command Line Tools. Then:

```sh
sudo installer -pkg rust-<version>.pkg -target /
```

In a new Terminal:

```sh
rustc hello.rs
./hello
```

### From Apple Silicon

```sh
sudo installer -pkg rust-cross-<version>.pkg -target /
```

In a new Terminal:

```sh
SDKROOT=/path/to/MacOSX10.9.sdk rustc --target x86_64-apple-darwin hello.rs
scp hello your-mavericks-system:
```

### From Linux

The `rust-<version>-linux-x86_64.tar.gz` toolchain runs on x86_64 Linux with glibc 2.35 or later. It
builds for Linux and for Mavericks. Unpack it anywhere: it is laid out under `opt/mavergreen/rust/`.

```sh
tar -xzf rust-<version>-linux-x86_64.tar.gz
export PATH="$PWD/opt/mavergreen/rust/bin:$PATH"
```

It has no default linker for Mavericks, so name clang22's. You need clang22's Linux archive
(`clang22-<version>-linux-x86_64.tar.gz` from
[clang-22's releases](https://github.com/Mavergreen/clang-22/releases/latest)) and the 10.9 SDK:

```sh
SDKROOT=/path/to/MacOSX10.9.sdk \
  rustc --target x86_64-apple-darwin -C linker=/path/to/clang22/bin/clang++ hello.rs
scp hello your-mavericks-system:
```

With cargo, name the linker for the target instead:

```sh
export SDKROOT=/path/to/MacOSX10.9.sdk
export CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER=/path/to/clang22/bin/clang++
cargo build --target x86_64-apple-darwin
```

For Mavericks, rustc adds the 10.9 deployment target and Recaulk, which supplies what 10.9 lacks.
Builds for Linux are not changed. They link with your system's `cc`.
