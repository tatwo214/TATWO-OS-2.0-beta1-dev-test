# Apply the same offline boundary to verify.sh without changing its tests or script.
swift() {
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    /usr/bin/swift "$@" --disable-sandbox --disable-automatic-resolution
}
