import Darwin
import DelsesCore

let app = DelsesApp()
let status = app.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(Int32(status))
