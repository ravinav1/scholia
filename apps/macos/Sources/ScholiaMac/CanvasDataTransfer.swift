import Foundation

/// Receive URLSession's chunks instead of suspending once for every byte.
/// Size limits apply to both declared and streamed lengths, including redirects.
final class CanvasDataTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let redirects: CanvasRedirectPolicy
    private let priority: CanvasDownloadTaskPriority?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var cancelled = false
    init(limit: Int, downloads: Bool, priority: CanvasDownloadTaskPriority? = nil) {
        self.limit = limit
        redirects = CanvasRedirectPolicy(downloads: downloads)
        self.priority = priority
    }

    func receive(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                let start = lock.withLock {
                    guard !cancelled else { return false }
                    self.continuation = continuation
                    self.task = task
                    task.priority = URLSessionTask.highPriority
                    priority?.register(task)
                    task.resume()
                    return true
                }
                if !start { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.cancel()
        }
    }
    private func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        finish(.failure(CancellationError()))
        task?.cancel()
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let (callback, finishedTask) = lock.withLock {
            let value = continuation
            let finishedTask = task
            continuation = nil
            task = nil
            data = Data()
            return (value, finishedTask)
        }
        if let finishedTask { priority?.remove(finishedTask) }
        callback?.resume(with: result)
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(StudyError.message("Canvas did not respond.")))
            completionHandler(.cancel)
            return
        }
        if !(200..<300).contains(http.statusCode) {
            finish(.success((Data(), http)))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= limit else {
            finish(.failure(StudyError.message("This Canvas resource exceeds the import size limit.")))
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let oversized = lock.withLock {
            guard continuation != nil else { return false }
            guard chunk.count <= limit - data.count else { return true }
            data.append(chunk)
            return false
        }
        if oversized {
            finish(.failure(StudyError.message("This Canvas resource exceeds the import size limit.")))
            dataTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<(Data, HTTPURLResponse), Error> = lock.withLock {
            if let error { return .failure(error) }
            guard let response else { return .failure(StudyError.message("Canvas did not respond.")) }
            return .success((data, response))
        }
        finish(result)
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirects.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: request,
            completionHandler: completionHandler)
    }
}
