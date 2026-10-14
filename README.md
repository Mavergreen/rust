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
