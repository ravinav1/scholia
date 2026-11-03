import Foundation
@testable import ScholiaMac

@main
struct StateTransportSmoke {
    static func main() {
        let original = StudyHTTPResponse(data: Data("{\"draft\":\"Private question\"}".utf8),
            headers: ["ETag": "\"revision-1\""])
        let unchanged = original.revalidated(ifNoneMatch: "\"old\", W/\"revision-1\"")
        precondition(unchanged.status == 304 && unchanged.data.isEmpty)
        let wire = String(decoding: unchanged.serialized(), as: UTF8.self)
        precondition(wire.hasPrefix("HTTP/1.1 304 Not Modified\r\n"))
        precondition(wire.contains("Cache-Control: no-store\r\n"))
        precondition(wire.contains("ETag: \"revision-1\"\r\n"))
        precondition(!wire.contains("Private question") && wire.hasSuffix("\r\n\r\n"))
        precondition(original.status == 200 && !original.data.isEmpty)
        for validator in [nil, "\"old\"", "\"revision-10\""] {
            let changed = original.revalidated(ifNoneMatch: validator)
            precondition(changed.status == 200 && changed.data == original.data)
        }
        precondition(StudyHTTPResponse.error(403, "Reopen Scholia").revalidated(ifNoneMatch: "*").status == 403)
        let asset = StudyHTTPResponse(data: Data("export {};".utf8), type: "text/javascript",
            headers: ["ETag": "W/\"file-revision\"", "Cache-Control": "private, no-cache"])
        let revalidated = asset.revalidated(ifNoneMatch: "\"file-revision\"")
        let assetWire = String(decoding: revalidated.serialized(), as: UTF8.self)
        precondition(revalidated.status == 304 && revalidated.data.isEmpty)
        precondition(assetWire.contains("Cache-Control: private, no-cache\r\n"))
        precondition(!assetWire.contains("Cache-Control: no-store"))
        print("PASS: native 304 wire responses, weak/list validators, full snapshot preservation, private state policy, and asset revalidation")
    }
}
