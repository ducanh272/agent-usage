# Testing

- Run the package tests from the repository root with `swift test --disable-sandbox`.
- Write new unit tests with Swift Testing (`import Testing`, `@Test`, and `#expect`). The Command Line Tools installation used for this project does not provide XCTest.
- On this machine, use the following command to select the working SDK and writable compiler caches:

  ```sh
  CLANG_MODULE_CACHE_PATH=/private/tmp/agent-usage-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/agent-usage-swift-cache \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift test --disable-sandbox
  ```

- If that SDK path is absent on another Mac, use its installed macOS SDK instead. The selected Swift compiler and SDK must be compatible.
