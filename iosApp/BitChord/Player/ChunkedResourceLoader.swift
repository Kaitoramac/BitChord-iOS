import AVFoundation
import UniformTypeIdentifiers

/// Serves a stream whose server only answers bounded `Range` requests.
///
/// AVPlayer asks for open-ended ranges (`bytes=N-`), which some YouTube clients'
/// URLs refuse; InnerTubeX flags those as `requiresBoundedRange`. The asset is
/// opened under a private scheme so every read comes here, and each read is
/// fetched in chunks no larger than the server accepts. Also used to attach
/// the stream's required headers without relying on private AVURLAsset keys.
final class ChunkedResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "bitchord-chunked"

    private let realURL: URL
    private let headers: [String: String]
    private let chunkSize: Int64
    private var contentLength: Int64?
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    let queue = DispatchQueue(label: "bitchord.chunked-loader")

    init(url: URL, headers: [String: String], chunkSize: Int64, contentLength: Int64?) {
        self.realURL = url
        self.headers = headers
        self.chunkSize = max(chunkSize, 256 * 1024)
        self.contentLength = contentLength
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// The URL to give AVURLAsset: the real one under [scheme].
    var assetURL: URL {
        var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        return components.url!
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serve(loadingRequest)
                if !Task.isCancelled { loadingRequest.finishLoading() }
            } catch {
                if !Task.isCancelled { loadingRequest.finishLoading(with: error) }
            }
            self.lock.withLock { _ = self.tasks.removeValue(forKey: key) }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async throws {
        let total = try await totalLength()

        if let info = request.contentInformationRequest {
            info.contentType = UTType.mpeg4Audio.identifier
            info.contentLength = total
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else { return }
        var offset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? total
            : min(total, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))

        while offset < end {
            try Task.checkCancellation()
            let upper = min(offset + chunkSize, end) - 1
            let data = try await fetch(from: offset, through: upper)
            guard !data.isEmpty else { break }
            dataRequest.respond(with: data)
            offset += Int64(data.count)
        }
    }

    private func totalLength() async throws -> Int64 {
        if let contentLength = lock.withLock({ self.contentLength }) { return contentLength }
        var request = URLRequest(url: realURL)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else {
            throw URLError(.badServerResponse)
        }
        lock.withLock { contentLength = total }
        return total
    }

    private func fetch(from start: Int64, through end: Int64) async throws -> Data {
        var request = URLRequest(url: realURL)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: ["status": (response as? HTTPURLResponse)?.statusCode ?? 0])
        }
        return data
    }
}
