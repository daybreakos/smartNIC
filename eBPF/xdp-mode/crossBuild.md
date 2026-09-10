# Cross build

Musl:
$ rustup target add aarch64-unknown-linux-musl

```shell
CC=aarch64-linux-gnu-gcc cargo build --package xdp-mode --target=aarch64-unknown-linux-musl \
--config=target.aarch64-unknown-linux-musl.linker=\"aarch64-linux-musl-gcc\"

# release
CC=aarch64-linux-gnu-gcc cargo build --package xdp-mode --target=aarch64-unknown-linux-musl --release \
--config=target.aarch64-unknown-linux-musl.linker=\"aarch64-linux-musl-gcc\"
```

Regular gnu glib linking
```shell
CC=aarch64-linux-gnu-gcc cargo build --package xdp-mode --release \
    --target=aarch64-unknown-linux-gnu \
    --config 'target.aarch64-unknown-linux-gnu.linker="aarch64-linux-gnu-gcc"'
```
