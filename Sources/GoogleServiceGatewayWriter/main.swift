import GoogleGatewayAuth
import Foundation

let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .service, role: "writer")

let result = await WriterAdapter().run(arguments: gatewayInvocation.arguments, environment: gatewayInvocation.environment)
let handle = result.isError ? FileHandle.standardError : FileHandle.standardOutput
handle.write(Data((result.output + "\n").utf8))
exit(gatewayInvocation.complete(exitCode: result.exitStatus))
