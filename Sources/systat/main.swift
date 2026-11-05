import AppKit

let systatVersion = "0.1.0"

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("systat \(systatVersion)")
    exit(0)
}
if arguments.contains("--sample") {
    exit(await SampleDump.run())
}
print("systat")
