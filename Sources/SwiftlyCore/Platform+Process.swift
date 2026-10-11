import Foundation
import Subprocess
#if os(macOS)
import System
#endif

import SystemPackage

extension Subprocess.Executable {
#if os(macOS)
    public static func path(_ filePath: SystemPackage.FilePath) -> Self {
        .path(System.FilePath(filePath.string))
    }
#endif
}

#if os(Windows)
private let pathSeparator: Character = ";"
#else
private let pathSeparator: Character = ":"
#endif

extension Platform {
#if os(macOS) || os(Linux) || os(Windows)
    public func proxyEnvironment(_ ctx: SwiftlyCoreContext, env: Environment, toolchain: ToolchainVersion) async throws -> Environment {
        var environment = env

        let tcPath = try await self.findToolchainBinDir(ctx, toolchain)
        guard try await fs.exists(atPath: tcPath) else {
            throw SwiftlyError(
                message:
                "Toolchain \(toolchain) could not be located in \(tcPath). You can try `swiftly uninstall \(toolchain)` to uninstall it and then `swiftly install \(toolchain)` to install it again."
            )
        }

#if os(Windows)
        // Environment variable names are case-insensitive on Windows, where it is usually spelled "Path".
        let path = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
#else
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
#endif
        var pathComponents = path.split(separator: pathSeparator).map { String($0) }

        // The toolchain goes to the beginning of the PATH
        pathComponents.removeAll(where: { $0 == tcPath.string })
        pathComponents = [tcPath.string] + pathComponents

        // Remove swiftly bin directory from the PATH entirely
        let swiftlyBinDir = self.swiftlyBinDir(ctx)
        pathComponents.removeAll(where: { $0 == swiftlyBinDir.string })

        let newPath = pathComponents.joined(separator: String(pathSeparator))
        environment = environment.updating(["PATH": newPath])
        environment = try await self.updateEnvironmentWithToolchain(ctx, environment, toolchain, path: newPath)

        return environment
    }

#endif
}
