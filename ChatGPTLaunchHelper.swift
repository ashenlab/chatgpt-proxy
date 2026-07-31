import AppKit
import Foundation

private let proxyEnvironmentNames = [
    "ALL_PROXY", "HTTP_PROXY", "HTTPS_PROXY",
    "all_proxy", "http_proxy", "https_proxy",
    "NO_PROXY", "no_proxy"
]

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ChatGPT launch failed: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4, arguments[0] == "--pid-file" else {
    fail("usage: chatgpt-launch-helper --pid-file PATH APP_PATH -- [ARGUMENTS]")
}

let pidFilePath = arguments[1]
let appPath = arguments[2]
guard arguments[3] == "--" else {
    fail("missing -- before ChatGPT arguments")
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("cannot find ChatGPT app at \(appPath)")
}

let inheritedEnvironment = ProcessInfo.processInfo.environment
var proxyEnvironment: [String: String] = [:]
for name in proxyEnvironmentNames {
    if let value = inheritedEnvironment[name] {
        proxyEnvironment[name] = value
    }
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.createsNewApplicationInstance = true
configuration.allowsRunningApplicationSubstitution = false
configuration.arguments = Array(arguments.dropFirst(4))
configuration.environment = proxyEnvironment

var terminationObserver: NSObjectProtocol?
NSWorkspace.shared.openApplication(
    at: URL(fileURLWithPath: appPath),
    configuration: configuration
) { application, error in
    if let error {
        fail(error.localizedDescription)
    }
    guard let application else {
        fail("LaunchServices did not return the ChatGPT process")
    }

    let pid = application.processIdentifier
    do {
        try "\(pid)\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pidFilePath
        )
    } catch {
        application.terminate()
        fail("cannot record the ChatGPT process: \(error.localizedDescription)")
    }

    terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
    ) { notification in
        guard let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              terminated.processIdentifier == pid else {
            return
        }
        exit(0)
    }

    if application.isTerminated {
        exit(0)
    }
}

RunLoop.main.run()
