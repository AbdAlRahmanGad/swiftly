import Foundation
import SwiftlyCore
import SystemPackage

/// Reads the containers of a WiX Burn bundle executable, such as the Swift toolchain installer.
///
/// A bundle is the Burn engine (the "stub") followed by its containers, which are cabinet files. They are
/// described by the `.wixburn` section of the executable:
///
/// ```
/// DWORD dwMagic;                      // 0x00f14300
/// DWORD dwVersion;
/// GUID  guidBundleId;
/// DWORD dwStubSize;                   // the containers start after the stub
/// DWORD dwOriginalChecksum;
/// DWORD dwOriginalSignatureOffset;    // where the stub's signature was placed
/// DWORD dwOriginalSignatureSize;
/// DWORD dwFormat;                     // 1 = cabinet
/// DWORD cContainers;
/// DWORD rgcbContainers[cContainers];  // the size of each container
/// ```
struct BurnBundle {
    private static let magic: UInt32 = 0x00F1_4300

    struct Payload {
        /// The name of the payload in the attached container's cabinet, e.g. "a0".
        var sourcePath: String
        /// The file name of the payload, e.g. "rtl.msi".
        var filePath: String
    }

    let path: FilePath
    private let stubSize: UInt64
    private let signatureOffset: UInt64
    private let signatureSize: UInt64
    private let containerSizes: [UInt64]

    init(path: FilePath) throws {
        self.path = path

        guard let handle = FileHandle(forReadingAtPath: path.string) else {
            throw SwiftlyError(message: "Could not open \(path)")
        }
        defer { try? handle.close() }

        let headers = try handle.read(upToCount: 4096) ?? Data()
        func u16(_ data: Data, _ offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        // Locate the .wixburn section through the PE section table.
        guard headers.starts(with: [0x4D, 0x5A]), // "MZ"
              let peOffset = u32(headers, 0x3C).map(Int.init),
              u32(headers, peOffset) == 0x0000_4550, // "PE\0\0"
              let sectionCount = u16(headers, peOffset + 6),
              let optionalHeaderSize = u16(headers, peOffset + 20)
        else {
            throw SwiftlyError(message: "\(path) is not a Windows executable")
        }

        var sectionOffset: UInt64?
        var sectionHeader = peOffset + 24 + Int(optionalHeaderSize)
        for _ in 0..<sectionCount {
            guard sectionHeader + 40 <= headers.count else { break }
            let name = headers[headers.startIndex + sectionHeader..<headers.startIndex + sectionHeader + 8]
            if Array(name.prefix { $0 != 0 }) == Array(".wixburn".utf8) {
                sectionOffset = u32(headers, sectionHeader + 20).map(UInt64.init)
                break
            }
            sectionHeader += 40
        }

        guard let sectionOffset else {
            throw SwiftlyError(message: "\(path) is not a WiX Burn bundle")
        }

        try handle.seek(toOffset: sectionOffset)
        let section = try handle.read(upToCount: 512) ?? Data()
        guard u32(section, 0) == Self.magic,
              let stubSize = u32(section, 24),
              let signatureOffset = u32(section, 32),
              let signatureSize = u32(section, 36),
              u32(section, 40) == 1, // cabinet format
              let containerCount = u32(section, 44)
        else {
            throw SwiftlyError(message: "\(path) has an unsupported WiX Burn bundle format")
        }

        var containerSizes: [UInt64] = []
        for i in 0..<Int(containerCount) {
            guard let size = u32(section, 48 + i * 4) else {
                throw SwiftlyError(message: "\(path) has an unsupported WiX Burn bundle format")
            }
            containerSizes.append(UInt64(size))
        }

        self.stubSize = UInt64(stubSize)
        self.signatureOffset = UInt64(signatureOffset)
        self.signatureSize = UInt64(signatureSize)
        self.containerSizes = containerSizes
    }

    /// Writes each container to a cabinet file in the given directory, returning their paths in order.
    func extractContainers(into dir: FilePath) throws -> [FilePath] {
        guard let handle = FileHandle(forReadingAtPath: path.string) else {
            throw SwiftlyError(message: "Could not open \(self.path)")
        }
        defer { try? handle.close() }

        var cabinets: [FilePath] = []
        var offset = self.stubSize
        for (index, size) in self.containerSizes.enumerated() {
            // The signature of the stub sits between the containers when the bundle has been signed.
            if self.signatureSize != 0 && offset == self.signatureOffset {
                offset += self.signatureSize
            }

            let cabinet = dir / "container\(index).cab"
            guard FileManager.default.createFile(atPath: cabinet.string, contents: nil),
                  let output = FileHandle(forWritingAtPath: cabinet.string)
            else {
                throw SwiftlyError(message: "Could not create \(cabinet)")
            }
            defer { try? output.close() }

            try handle.seek(toOffset: offset)
            var remaining = size
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 16 * 1024 * 1024))), !chunk.isEmpty else {
                    throw SwiftlyError(message: "\(self.path) is truncated")
                }
                if remaining == size && !chunk.starts(with: Array("MSCF".utf8)) {
                    throw SwiftlyError(message: "\(self.path) has an unsupported WiX Burn container")
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }

            cabinets.append(cabinet)
            offset += size
        }

        return cabinets
    }

    /// The payloads of the attached container, from the bundle's manifest (BurnManifest.xml).
    static func attachedPayloads(manifest: String) -> [Payload] {
        guard let element = try? Regex(#"<Payload\s[^>]*>"#),
              let attribute = try? Regex(#"(\w+)="([^"]*)""#)
        else {
            return []
        }

        return manifest.matches(of: element).compactMap { match in
            var attributes: [String: String] = [:]
            for attr in match.output[0].substring?.matches(of: attribute) ?? [] {
                if let name = attr.output[1].substring, let value = attr.output[2].substring {
                    attributes[String(name)] = String(value)
                }
            }

            guard attributes["Container"] == "WixAttachedContainer",
                  let sourcePath = attributes["SourcePath"],
                  let filePath = attributes["FilePath"]
            else {
                return nil
            }
            return Payload(sourcePath: sourcePath, filePath: filePath)
        }
    }
}
