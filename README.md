# Rust for Mavericks

Rust toolchain for Mac OS X 10.9 Mavericks.

Included:

- `cargo` (and `cargo clippy` and `cargo fmt`)
- `rustdoc`

## Compiling

### Directly on Mavericks

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
