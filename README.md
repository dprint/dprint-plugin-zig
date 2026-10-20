# dprint-plugin-zig

[![npm version](https://img.shields.io/npm/v/@dprint/zig.svg)](https://www.npmjs.com/package/@dprint/zig) [![CI](https://github.com/dprint/dprint-plugin-zig/workflows/CI/badge.svg)](https://github.com/dprint/dprint-plugin-zig/actions?query=workflow%3ACI)

Wrapper for [Zig](https://ziglang.org)'s formatter (`zig fmt`) for use as a formatting plugin in [dprint](https://github.com/dprint/dprint). It formats Zig (`.zig`) and ZON (`.zon`) files exactly like `zig fmt` does, since it's the parser and renderer of Zig's own std (`std.zig.Ast`) compiled to Wasm.

## Install

[Install](https://dprint.dev/install/) and [setup](https://dprint.dev/setup/) dprint.

Then in your project's directory with a dprint.json file, run:

```shellsession
dprint add zig
```

Note: You do not need Zig installed globally as dprint will run the formatter from the .wasm file in a sandboxed environment.

## Configuration

There's nothing to configure, since `zig fmt` has no formatting options. The `"zig"` key in your dprint.json is only there for consistency with other plugins, and any property in it is reported as unknown:

```jsonc
{
  "zig": {},
  "plugins": [
    // ...etc...
  ],
}
```

The global configuration doesn't apply either. Like `zig fmt`, the plugin always indents with four spaces, has no line width, and outputs LF newlines, so a file with CRLF newlines is formatted to LF regardless of `newLineKind`. Range formatting isn't supported, so a request to format part of a file leaves it as it is.

Like `zig fmt`, a `.zon` file is formatted as ZON, a UTF-16 little endian file is formatted to UTF-8, and a file that doesn't parse is an error with the same message `zig fmt` gives (without the file path, since dprint already says which file it is). The plugin doesn't run `zig fmt --ast-check`'s extra checks.

## JS Formatting API

- [JS Formatter](https://github.com/dprint/js-formatter) - Browser/Deno and Node
- [npm package](https://www.npmjs.com/package/@dprint/zig)

## Versioning

This repo automatically upgrades to the latest stable release of Zig once a day. You can check which version of Zig is being used by looking at `minimum_zig_version` in the build.zig.zon file in this repo:

https://github.com/dprint/dprint-plugin-zig/blob/main/build.zig.zon

At the moment, the version of this plugin does not reflect the version of Zig.

## Development

The plugin is written in Zig and builds with the Zig version in build.zig.zon, which `build.zig` requires exactly, since the formatter is part of Zig's std. It's a `wasm32-freestanding` module with no imports, so it doesn't rely on the dprint CLI providing WASI.

```shellsession
zig build test --summary all # unit tests, plus spec tests comparing against `zig fmt`
zig build # outputs zig-out/plugin.wasm
```

The spec tests format each file in `tests/specs` with the plugin and with `zig fmt` of the Zig running the tests, and check that the output (or the parse error) is the same.

## Credits

- [Zig](https://ziglang.org) by the Zig contributors, under the MIT license.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details. See [third_party](third_party) for the license of the Zig code it includes.
