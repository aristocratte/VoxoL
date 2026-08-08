import Foundation

final class ResumableFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let partialURL: URL
    private let expectedSize: Int64
    private let requestedOffset: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileHandle: FileHandle?
    private var receivedBytes: Int64 = 0
    private var lastProgressTime: TimeInterval = 0
    private var isCancelled = false
    private var isFinished = false

    init(
        sourceURL: URL,
        partialURL: URL,
        expectedSize: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) throws {
        self.sourceURL = sourceURL
        self.partialURL = partialURL
        self.expectedSize = expectedSize
        self.progress = progress

        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingSize = Self.fileSize(at: partialURL)
        if existingSize > expectedSize {
            try FileManager.default.removeItem(at: partialURL)
            requestedOffset = 0
        } else {
            requestedOffset = existingSize
        }
        super.init()
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 86_400
                configuration.waitsForConnectivity = true

                let delegateQueue = OperationQueue()
                delegateQueue.name = "com.voxol.model-download"
                delegateQueue.maxConcurrentOperationCount = 1

                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                var request = URLRequest(url: sourceURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if requestedOffset > 0 {
                    request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range")
                }
                let task = session.dataTask(with: request)

                let shouldCancel = lock.withLock {
                    self.session = session
                    dataTask = task
                    self.continuation = continuation
                    return isCancelled
                }
                task.resume()
                if shouldCancel {
                    task.cancel()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return dataTask
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirectedRequest = request
        if requestedOffset > 0 {
            redirectedRequest.setValue(
                "bytes=\(requestedOffset)-",
                forHTTPHeaderField: "Range"
            )
        }
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse else {
                throw ResumableDownloadError.invalidResponse
            }

            let shouldAppend: Bool
            switch http.statusCode {
            case 200:
                shouldAppend = false
                receivedBytes = 0
            case 206:
                guard
                    Self.hasValidContentRange(
                        http.value(forHTTPHeaderField: "Content-Range"),
                        offset: requestedOffset,
                        expectedSize: expectedSize
                    )
                else {
                    throw ResumableDownloadError.invalidContentRange
                }
                shouldAppend = requestedOffset > 0
                receivedBytes = requestedOffset
            default:
                throw ResumableDownloadError.invalidResponse
            }

            if !FileManager.default.fileExists(atPath: partialURL.path) {
                guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                    throw ResumableDownloadError.cannotCreatePartialFile
                }
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            if shouldAppend {
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: 0)
            }
            fileHandle = handle
            progress(receivedBytes)
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            guard let fileHandle else {
                throw ResumableDownloadError.cannotCreatePartialFile
            }
            try fileHandle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            guard receivedBytes <= expectedSize else {
                throw ResumableDownloadError.downloadSizeMismatch
            }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgressTime >= 0.08 || receivedBytes == expectedSize {
                lastProgressTime = now
                progress(receivedBytes)
            }
        } catch {
            dataTask.cancel()
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(with: .failure(error))
        } else if receivedBytes == expectedSize {
            progress(receivedBytes)
            finish(with: .success(()))
        } else {
            finish(with: .failure(ResumableDownloadError.downloadSizeMismatch))
        }
    }

    private func finish(with result: Result<Void, Error>) {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        let continuation = lock.withLock {
            guard !isFinished else {
                return nil as CheckedContinuation<Void, Error>?
            }
            isFinished = true
            let continuation = self.continuation
            self.continuation = nil
            dataTask = nil
            return continuation
        }
        session?.finishTasksAndInvalidate()
        session = nil

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private extension ResumableFileDownload {
    static func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    static func hasValidContentRange(
        _ value: String?,
        offset: Int64,
        expectedSize: Int64
    ) -> Bool {
        guard let value else {
            return false
        }
        return value.hasPrefix("bytes \(offset)-") && value.hasSuffix("/\(expectedSize)")
    }
}

private enum ResumableDownloadError: Error {
    case invalidResponse
    case invalidContentRange
    case cannotCreatePartialFile
    case downloadSizeMismatch
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
