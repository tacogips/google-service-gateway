import GoogleGatewayAuth
import Foundation

let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .service, role: "reader")

let result = await ReaderAdapter().run(arguments: gatewayInvocation.arguments, environment: gatewayInvocation.environment)
let handle = result.isError ? FileHandle.standardError : FileHandle.standardOutput
handle.write(Data((result.output + "\n").utf8))
exit(gatewayInvocation.complete(exitCode: result.exitStatus))
