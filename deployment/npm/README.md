# @dprint/zig

npm distribution of [dprint-plugin-zig](https://github.com/dprint/dprint-plugin-zig) which is a wrapper plugin for [Zig](https://ziglang.org)'s formatter (`zig fmt`).

Use this with [@dprint/formatter](https://github.com/dprint/js-formatter) or just use @dprint/formatter and download the [dprint-plugin-zig Wasm file](https://github.com/dprint/dprint-plugin-zig/releases).

## Example

```ts
import { createFromBuffer } from "@dprint/formatter";
import { getBuffer } from "@dprint/zig";

const formatter = createFromBuffer(getBuffer());

console.log(formatter.formatText({
  filePath: "file.zig",
  fileText: "const   x = 1;\n",
}));
```
