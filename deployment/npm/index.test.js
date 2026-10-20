// @ts-check
const assert = require("assert");
const createFromBuffer = require("@dprint/formatter").createFromBuffer;
const getBuffer = require("./index").getBuffer;

const formatter = createFromBuffer(getBuffer());

assert.deepStrictEqual(formatter.getFileMatchingInfo(), {
  fileExtensions: ["zig", "zon"],
  fileNames: [],
  additive: false,
});

assert.strictEqual(
  formatter.formatText({
    filePath: "file.zig",
    fileText: "const   std = @import(\"std\");\npub fn main() void {\nstd.debug.print(\"hi\\n\", .{});\n}",
  }),
  "const std = @import(\"std\");\npub fn main() void {\n    std.debug.print(\"hi\\n\", .{});\n}\n",
);

// zon is formatted as zon
assert.strictEqual(
  formatter.formatText({
    filePath: "build.zig.zon",
    fileText: ".{ .name = .example, .version = \"0.0.0\", }",
  }),
  ".{\n    .name = .example,\n    .version = \"0.0.0\",\n}\n",
);

// zig fmt has no options, so they're all unknown
formatter.setConfig({ indentWidth: 2 }, { indentWidth: 2 });
assert.deepStrictEqual(formatter.getConfigDiagnostics(), [{
  propertyName: "indentWidth",
  message: "Unknown property in configuration",
}]);
formatter.setConfig({}, {});
assert.deepStrictEqual(formatter.getConfigDiagnostics(), []);
assert.deepStrictEqual(formatter.getResolvedConfig(), {});

assert.throws(
  () => formatter.formatText({ filePath: "file.zig", fileText: "const x = 1\n" }),
  /1:12: error: expected ';' after declaration/,
);
