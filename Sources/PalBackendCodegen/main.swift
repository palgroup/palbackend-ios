import Foundation

// PalBackendCodegen — reads an OpenAPI 3.1 document and writes a Swift file
// of namespaced, typed backend calls. Invoked by the PalBackendGen build-tool
// plugin (build-time, sandboxed, no network) and usable standalone.
//
// Usage: PalBackendCodegen <input.openapi.json> -o <output.swift>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("PalBackendCodegen: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let inputPath = args.first else {
    fail("missing input path. Usage: PalBackendCodegen <input.openapi.json> -o <output.swift>")
}

var outputPath: String?
var i = 1
while i < args.count {
    if args[i] == "-o", i + 1 < args.count { outputPath = args[i + 1]; i += 2 }
    else { i += 1 }
}
guard let outputPath else {
    fail("missing -o <output.swift>")
}

let data: Data
do {
    data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
} catch {
    fail("cannot read \(inputPath): \(error.localizedDescription)")
}

let operations: [Operation]
do {
    operations = try OpenAPIParser.parse(data)
} catch {
    fail("\(error)")
}

let swift = SwiftEmitter.emit(operations: operations)

do {
    try swift.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
} catch {
    fail("cannot write \(outputPath): \(error.localizedDescription)")
}

FileHandle.standardError.write(Data("PalBackendCodegen: wrote \(operations.count) operation(s) → \(outputPath)\n".utf8))
