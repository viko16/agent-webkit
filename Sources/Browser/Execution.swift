import Foundation

/// WebKit callbacks can arrive after a timeout or never arrive after process exit.
/// Complete the caller exactly once without waiting for the WebContent process.
@MainActor
final class PendingOperation<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func arm(milliseconds: Double,
             error: Error = BrowserError("timeout", "WebKit 执行超时；操作可能已部分生效。请查询 state，必要时 reload 后重新 snapshot"),
             onTimeout: @escaping () -> Void) {
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.continuation != nil else { return }
                onTimeout()
                self.finish(.failure(error))
            }
        }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: timer)
    }

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
}
