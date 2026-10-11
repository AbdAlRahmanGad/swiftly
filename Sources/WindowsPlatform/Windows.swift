import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage

typealias fs = SwiftlyCore.FileSystem

/// `Platform` implementation for Windows systems.
///
/// Toolchains are distributed as WiX Burn bundle installers on Windows. Rather than running the installer, which
/// registers a single per-user installation, swiftly extracts the bundle's MSI packages and performs an
/// administrative install of each of them into a toolchain specific directory. This lays out the files
/// without registering anything with the system, so that multiple toolchains can live side by side.
public struct Windows: Platform {
    public init() {}

    private let SWIFTLY_TOOLCHAINS_DIR = "SWIFTLY_TOOLCHAINS_DIR"

    /// Where the runtime DLLs are placed, relative to the toolchain root.
    private let runtimeBinDir = FilePath("Runtimes") / "usr" / "bin"

    public var defaultSwiftlyHomeDir: FilePath {
        if let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] {
            return FilePath(localAppData) / "swiftly"
        }
        return fs.home / "AppData" / "Local" / "swiftly"
    }

    public func swiftlyBinDir(_ ctx: SwiftlyCoreContext) -> FilePath {
        ctx.mockedHomeDir.map { $0 / "bin" }
            ?? ProcessInfo.processInfo.environment["SWIFTLY_BIN_DIR"].map { FilePath($0) }
            ?? self.swiftlyHomeDir(ctx) / "bin"
    }

    public func swiftlyToolchainsDir(_ ctx: SwiftlyCoreContext) -> FilePath {
        ctx.mockedHomeDir.map { $0 / "toolchains" }
            ?? ProcessInfo.processInfo.environment[self.SWIFTLY_TOOLCHAINS_DIR].map { FilePath($0) }
            ?? self.swiftlyHomeDir(ctx) / "toolchains"
    }

    public func escapePathForShell(_ path: FilePath) -> String {
        // PowerShell single-quoted string
        "'\(path.string.replacingOccurrences(of: "'", with: "''"))'"
    }

    public var toolchainFileExtension: String {
        "exe"
    }

    public func verifySwiftlySystemPrerequisites() throws {}

    public func verifySystemPrerequisitesForInstall(
        _: SwiftlyCoreContext, platformName _: String, version _: ToolchainVersion,
        requireSignatureValidation _: Bool
    ) async throws -> String? {
        nil
    }

    /// The directory that holds the files of an installed toolchain.
    private func toolchainRoot(_ ctx: SwiftlyCoreContext, _ version: ToolchainVersion) -> FilePath {
        self.swiftlyToolchainsDir(ctx) / version.identifier
    }

    public func install(
        _ ctx: SwiftlyCoreContext, from tmpFile: FilePath, version: ToolchainVersion, verbose: Bool
    ) async throws {
        guard try await fs.exists(atPath: tmpFile) else {
            throw SwiftlyError(message: "\(tmpFile) doesn't exist")
        }

        let toolchainsDir = self.swiftlyToolchainsDir(ctx)
        if !(try await fs.exists(atPath: toolchainsDir)) {
            try await fs.mkdir(.parents, atPath: toolchainsDir)
        }

        let workDir = fs.mktemp()
        try await fs.mkdir(.parents, atPath: workDir)
        defer { try? FileManager.default.removeItem(atPath: workDir.string) }

        await ctx.message("Extracting installer packages...")
        let packages = try await self.extractBundlePackages(tmpFile, into: workDir)

        let toolchainRoot = self.toolchainRoot(ctx, version)
        if try await fs.exists(atPath: toolchainRoot) {
            try await fs.remove(atPath: toolchainRoot)
        }

        // msiexec can't write paths longer than MAX_PATH, and the packages nest their files deeply under the
        // installer's default install root. Extract them into a short staging directory next to the final
        // location, flatten that, and then move it into place.
        let stagingDir = toolchainsDir / "~\(UUID().uuidString.prefix(4))"
        try await fs.mkdir(.parents, atPath: stagingDir)

        do {
            for package in packages {
                let name = package.lastComponent?.string.lowercased() ?? ""
                // The Android SDK isn't needed to build for Windows.
                guard name != "android.msi" else { continue }

                // The runtime package installs its files directly into the target directory.
                let targetDir = name == "rtl.msi" ? stagingDir.pushing(self.runtimeBinDir) : stagingDir

                if verbose {
                    await ctx.message("Extracting \(name)...")
                }
                // An administrative install extracts the files without registering the package with the system.
                try await self.runProgram(
                    FilePath("msiexec.exe"),
                    ["/a", package.string, "/qn", "TARGETDIR=\(targetDir.string)"]
                )
            }

            try await self.flattenInstallRoot(stagingDir)
            try await fs.move(atPath: stagingDir, toPath: toolchainRoot)
        } catch {
            try? await fs.remove(atPath: stagingDir)
            throw error
        }

        guard (try? await self.findToolchainLocation(ctx, version)) != nil else {
            throw SwiftlyError(message: "The toolchain could not be found after extracting it to \(toolchainRoot)")
        }
    }

    /// The packages lay out their files under the installer's default install root (e.g. LocalApp\Programs\Swift).
    /// Move the contents of that directory up into the toolchain root.
    private func flattenInstallRoot(_ toolchainRoot: FilePath) async throws {
        // An administrative install leaves a copy of each MSI in the target directory, which isn't needed.
        for file in try await fs.ls(atPath: toolchainRoot) where file.lowercased().hasSuffix(".msi") {
            try await fs.remove(atPath: toolchainRoot / file)
        }

        // Breadth-first search for the directory containing "Toolchains".
        var queue = [toolchainRoot]
        var installRoot: FilePath?
        while !queue.isEmpty, installRoot == nil {
            let dir = queue.removeFirst()
            let contents = (try? await fs.ls(atPath: dir)) ?? []
            if contents.contains("Toolchains") {
                installRoot = dir
            } else if dir.components.count - toolchainRoot.components.count < 4 {
                for entry in contents {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: (dir / entry).string, isDirectory: &isDirectory), isDirectory.boolValue {
                        queue.append(dir / entry)
                    }
                }
            }
        }

        guard let installRoot else {
            throw SwiftlyError(message: "No toolchain was found in the installer packages")
        }

        guard installRoot != toolchainRoot else { return }

        for entry in try await fs.ls(atPath: installRoot) {
            try await fs.move(atPath: installRoot / entry, toPath: toolchainRoot / entry)
        }

        // Remove the now empty top-level directory, such as "LocalApp".
        if let top = installRoot.components.dropFirst(toolchainRoot.components.count).first {
            try await fs.remove(atPath: toolchainRoot.appending(top))
        }
    }

    /// Extracts the MSI packages, and their cabinets, from a WiX Burn bundle into the given directory.
    private func extractBundlePackages(_ bundle: FilePath, into dir: FilePath) async throws -> [FilePath] {
        let containers = try BurnBundle(path: bundle).extractContainers(into: dir)
        guard containers.count >= 2 else {
            throw SwiftlyError(message: "\(bundle) does not contain any packages")
        }

        // The first container holds the bundle's manifest, which describes the payloads of the second
        // (attached) container.
        let uxDir = dir / "ux"
        let payloadDir = dir / "payload"
        try await fs.mkdir(atPath: uxDir)
        try await fs.mkdir(atPath: payloadDir)
        try await self.expandCabinet(containers[0], into: uxDir)
        try await self.expandCabinet(containers[1], into: payloadDir)

        let manifest = String(decoding: try await fs.cat(atPath: uxDir / "0"), as: UTF8.self)
        var packages: [FilePath] = []
        for payload in BurnBundle.attachedPayloads(manifest: manifest) {
            try await fs.move(atPath: payloadDir / payload.sourcePath, toPath: payloadDir / payload.filePath)
            if payload.filePath.lowercased().hasSuffix(".msi") {
                packages.append(payloadDir / payload.filePath)
            }
        }

        guard !packages.isEmpty else {
            throw SwiftlyError(message: "\(bundle) does not contain any packages")
        }
        return packages
    }

    private func expandCabinet(_ cabinet: FilePath, into dir: FilePath) async throws {
        let systemRoot = FilePath(ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#)
        try await self.runProgram(systemRoot / "System32" / "expand.exe", ["-F:*", cabinet.string, dir.string])
    }

    private func runProgram(_ executable: FilePath, _ arguments: [String]) async throws {
        let config = Configuration(
            executable: executable.isAbsolute ? .path(executable) : .name(executable.string),
            arguments: Arguments(arguments)
        )
        let result = try await run(config, output: .discarded, error: .discarded)
        if !result.terminationStatus.isSuccess {
            throw RunProgramError(terminationStatus: result.terminationStatus, config: config)
        }
    }

    public func extractSwiftlyAndInstall(_: SwiftlyCoreContext, from _: FilePath) async throws {
        throw SwiftlyError(message: "Installing swiftly from an archive is not yet supported on Windows.")
    }

    public func uninstall(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion, verbose: Bool)
        async throws
    {
        if verbose {
            await ctx.message("Removing \(self.toolchainRoot(ctx, toolchain))...")
        }
        try await fs.remove(atPath: self.toolchainRoot(ctx, toolchain))
    }

    public func getExecutableName() -> String {
#if arch(x86_64)
        "swiftly-windows-x86_64.exe"
#elseif arch(arm64)
        "swiftly-windows-arm64.exe"
#endif
    }

    public func verifyToolchainSignature(
        _: SwiftlyCoreContext, toolchainFile _: ToolchainFile, archive _: FilePath, verbose _: Bool
    ) async throws {
        // TODO: verify the Authenticode signature of the installer.
    }

    public func verifySwiftlySignature(
        _: SwiftlyCoreContext, archiveDownloadURL _: URL, archive _: FilePath, verbose _: Bool
    ) async throws {
        // TODO: verify the Authenticode signature of swiftly.
    }

    public func detectPlatform(
        _: SwiftlyCoreContext, disableConfirmation _: Bool, platform _: String?
    ) async -> PlatformDefinition {
        .windows10
    }

    public func getShell() async throws -> String {
        "powershell"
    }

    public func findToolchainLocation(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion) async throws -> FilePath
    {
        // e.g. <toolchain root>\Toolchains\6.2.4+Asserts
        let toolchainsDir = self.toolchainRoot(ctx, toolchain) / "Toolchains"
        guard let name = try? await fs.ls(atPath: toolchainsDir).first else {
            throw SwiftlyError(message: "Toolchain \(toolchain) could not be found in \(toolchainsDir)")
        }
        return toolchainsDir / name
    }

    public func updateEnvironmentWithToolchain(_ ctx: SwiftlyCoreContext, _ environment: Environment, _ toolchain: ToolchainVersion, path: String) async throws -> Environment {
        let toolchainRoot = self.toolchainRoot(ctx, toolchain)

        // The runtime DLLs go right after the toolchain's bin directory, ahead of any other Swift runtime.
        var pathComponents = path.split(separator: ";").map(String.init)
        pathComponents.insert(toolchainRoot.pushing(self.runtimeBinDir).string, at: min(1, pathComponents.count))
        var newEnv = environment.updating(["PATH": pathComponents.joined(separator: ";")])

        // Point the compiler at this toolchain's Windows SDK, e.g.
        // <toolchain root>\Platforms\6.2.4\Windows.platform\Developer\SDKs\Windows.sdk
        let platformsDir = toolchainRoot / "Platforms"
        for platform in (try? await fs.ls(atPath: platformsDir)) ?? [] {
            let sdk = platformsDir / platform / "Windows.platform" / "Developer" / "SDKs" / "Windows.sdk"
            if try await fs.exists(atPath: sdk) {
                newEnv = newEnv.updating(["SDKROOT": sdk.string])
                break
            }
        }

        return newEnv
    }

    public static let currentPlatform: any Platform = Windows()
}
