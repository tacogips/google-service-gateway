import Foundation
import GoogleServiceGatewayCore

let result = await AuthAdapter().run(arguments: Array(CommandLine.arguments.dropFirst()))
let handle = result.isError ? FileHandle.standardError : FileHandle.standardOutput
handle.write(Data((result.output + "\n").utf8))
exit(result.exitStatus)
