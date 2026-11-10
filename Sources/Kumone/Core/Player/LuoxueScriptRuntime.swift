import Foundation
import JavaScriptCore
import Compression
import os.log

// MARK: - Error

enum LuoxueScriptError: LocalizedError {
    case noScript
    case notLoaded
    case scriptInitFailed(String)
    case scriptThrew(String)
    case noRequestHandler
    case noMusicURL
    case invalidURL(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noScript: return String(localized: "未安装自定义源脚本")
        case .notLoaded: return String(localized: "脚本未加载（初始化失败或超时）")
        case .scriptInitFailed(let reason): return String(localized: "脚本初始化失败：\(reason)")
        case .scriptThrew(let reason): return String(localized: "脚本错误：\(reason)")
        case .noRequestHandler: return String(localized: "脚本未注册请求处理器")
        case .noMusicURL: return String(localized: "脚本未返回播放链接")
        case .invalidURL(let value): return String(localized: "脚本返回了无效链接：\(value)")
        case .timedOut: return String(localized: "脚本超时")
        }
    }
}

// MARK: - Resolved stream

/// A resolved stream: the URL plus any headers the server insists on.
/// 网盘 sources often answer with `{ url, headers }` — the link only plays
/// when those headers (User-Agent / Referer / Cookie) ride along.
struct LuoxueResolvedMusic: Sendable {
    let url: URL
    let headers: [String: String]
    /// True when the URL did not come from the handler's return value but
    /// from the last link the script requested via `lx.request` — the
    /// lastRequestResolvedMusicURL fallback of the reference app.
    var fromRequestCapture: Bool = false
}

// MARK: - Engine input / output

/// One script handed to the engine for loading.
struct LxScriptInput {
    /// Caller-side identity (the installed-source UUID).
    let id: UUID
    /// Display name, used in logs.
    let name: String
    /// `@name/@description/@version/@author` header metadata.
    let meta: [String: String]
    /// The script body.
    let script: String
}

/// Load outcome of one script inside the shared context.
struct LxScriptResult {
    /// Source ids this script registered (`wy`, `tx`, …).
    var sources: [String] = []
    /// Non-nil when the script threw or reported `status: false`.
    var error: String?
}

/// Everything a `load` call reports back.
struct LxLoadResult {
    /// Merged `sourceId -> qualitys` across every loaded script.
    let capabilities: [String: [String]]
    /// Per-script outcome, keyed by the input's `id`.
    let scriptResults: [UUID: LxScriptResult]
}

// MARK: - JSExport bridges

/// Native surface the LX Music user script talks to. Every method is invoked
/// by JavaScriptCore on the engine's serial queue.
@objc protocol LxBridgeExports: JSExport {
    func consoleLog(_ message: JSValue)
    func httpRequest(_ url: JSValue, _ options: JSValue, _ callback: JSValue)
    func scriptEvent(_ name: JSValue, _ payload: JSValue, _ scriptId: JSValue)
    func bufferFrom(_ text: JSValue, _ type: JSValue) -> JSValue
    func bufferToString(_ buffer: JSValue, _ type: JSValue) -> JSValue
    func zlibInflate(_ buffer: JSValue) -> JSValue
    func zlibDeflate(_ buffer: JSValue) -> JSValue
}

/// Promise settlement callbacks handed to the script's handler result.
@objc protocol LxPromiseExports: JSExport {
    func resolve(_ value: JSValue)
    func reject(_ error: JSValue)
}

/// Wraps a `JSValue` so it can be captured by `@Sendable` closures; the value
/// itself is only ever touched on the engine queue.
final class LuoxueJSValueBox: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

// MARK: - Native bridge

final class LxNativeBridge: NSObject, LxBridgeExports {
    private weak var engine: LxScriptEngine?

    init(engine: LxScriptEngine) {
        self.engine = engine
        super.init()
    }

    private static let consoleLog = Logger(subsystem: "sb.moe.kumone", category: "lx-console")

    func consoleLog(_ message: JSValue) {
        let text = message.toString() ?? ""
        Self.consoleLog.info("\(text, privacy: .public)")
    }

    // MARK: HTTP

    func httpRequest(_ url: JSValue, _ options: JSValue, _ callback: JSValue) {
        guard let engine else { return }
        let request = engine.makeRequest(urlValue: url, optionsValue: options)
        let callbackBox = LuoxueJSValueBox(callback)
        guard let request else {
            engine.runOnQueue { [weak self] in
                self?.invokeCallback(callbackBox, error: "invalid request")
            }
            return
        }
        engine.performRequest(request) { [weak engine] result in
            engine?.runOnQueue { [weak self] in
                switch result {
                case .success(let response):
                    self?.invokeCallback(callbackBox, response: response)
                case .failure(let failure):
                    self?.invokeCallback(callbackBox, error: failure.message)
                }
            }
        }
    }

    private func invokeCallback(_ box: LuoxueJSValueBox, response: [String: Any]? = nil, error: String? = nil) {
        guard let engine, let context = engine.contextOnQueue else { return }
        let arguments: [Any]
        if let error {
            let errorObject = JSValue(object: ["message": error, "code": -1], in: context)
            arguments = [errorObject ?? JSValue(nullIn: context), JSValue(nullIn: context)]
        } else if let response, let responseValue = JSValue(object: response, in: context) {
            arguments = [JSValue(nullIn: context), responseValue]
        } else {
            let errorObject = JSValue(object: ["message": "request failed", "code": -1], in: context)
            arguments = [errorObject ?? JSValue(nullIn: context), JSValue(nullIn: context)]
        }
        box.value.call(withArguments: arguments)
    }

    // MARK: Lifecycle

    func scriptEvent(_ name: JSValue, _ payload: JSValue, _ scriptId: JSValue) {
        let attributedID: UUID?
        if scriptId.isString, let text = scriptId.toString(), let parsed = UUID(uuidString: text) {
            attributedID = parsed
        } else {
            attributedID = nil
        }
        engine?.handleScriptEvent(name.toString() ?? "", payload: payload, fromScriptID: attributedID)
    }

    // MARK: Buffers

    func bufferFrom(_ text: JSValue, _ type: JSValue) -> JSValue {
        guard let engine, let context = engine.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let string = text.isString ? (text.toString() ?? "") : ""
        let typeString = type.isString ? (type.toString() ?? "utf8") : "utf8"
        let bytes = LxBuffer.bytes(fromString: string, encoding: typeString)
        return JSValue(object: bytes, in: context) ?? JSValue(nullIn: context)
    }

    func bufferToString(_ buffer: JSValue, _ type: JSValue) -> JSValue {
        guard let engine, let context = engine.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let bytes = LxBuffer.bytes(from: buffer)
        let typeString = type.isString ? (type.toString() ?? "utf8") : "utf8"
        let string = LxBuffer.string(fromBytes: bytes, encoding: typeString)
        return JSValue(object: string, in: context) ?? JSValue(nullIn: context)
    }

    // MARK: zlib

    func zlibInflate(_ buffer: JSValue) -> JSValue {
        guard let engine, let context = engine.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let bytes = LxBuffer.bytes(from: buffer)
        return JSValue(object: LxZlib.inflate(bytes), in: context) ?? JSValue(nullIn: context)
    }

    func zlibDeflate(_ buffer: JSValue) -> JSValue {
        guard let engine, let context = engine.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let bytes = LxBuffer.bytes(from: buffer)
        return JSValue(object: LxZlib.deflate(bytes), in: context) ?? JSValue(nullIn: context)
    }
}

// MARK: - Engine

/// The LX Music custom-source engine, modeled one-to-one on the reference
/// app's (畅怡守/KMusic) implementation:
///
/// - every enabled script is evaluated into ONE shared `JSContext`, in list
///   order, each preceded by its own `lx.currentScriptInfo`;
/// - `lx.on(EVENT_NAMES.request, handler)` collects handlers into a list —
///   resolution walks handlers in order, and qualities within each handler
///   (`resolveMusicUrlWithFallback` + `retryWithLowerQualityIfPossible`);
/// - `lx.request` is wrapped so JSON-looking bodies become hybrid String
///   objects (`.json`/`.text`/`.data`/`.raw`), and every request captures the
///   URL (plus any URL found in the body) as the
///   `lastRequestResolvedMusicURL` fallback used when no handler produced a
///   link;
/// - `lx.utils` provides `buffer` and `zlib` (`_inflateSync`/`_deflateSync`
///   native, plus Promise wrappers), there is no `crypto` — matching the
///   reference app exactly;
/// - `atob`/`btoa`, `console` (with `group`/`groupEnd`), `window`,
///   `globalThis.cerumusic` (Promise request wrapper + `NoticeCenter` no-op)
///   and the CommonJS adapter (`module.exports.musicUrl` + `.sources`) are
///   all provided.
///
/// Thread model: the `JSContext` (and every `JSValue` derived from it) is
/// confined to `queue`. Public methods are async and hop onto that queue,
/// never passing `JSValue` across the boundary — only plain Sendable values.
final class LxScriptEngine {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "lx-engine")

    private let queue = DispatchQueue(label: "sb.moe.kun.lx-engine", qos: .userInitiated)
    private let session: URLSession
    private var context: JSContext?
    private var bridge: LxNativeBridge?
    /// sourceId -> qualitys, merged across scripts.
    private var capabilities: [String: [String]] = [:]
    /// Per-input-script outcome, keyed by the input's UUID.
    private var scriptResults: [UUID: LxScriptResult] = [:]
    /// Index of the script currently being evaluated, for error attribution.
    private var currentScriptID: UUID?
    /// The last URL candidate seen by `lx.request` — request URL itself or a
    /// URL extracted from a response body. Used as the final fallback.
    private var lastCapturedURL: String?
    /// Scripts still waiting on their `inited` event during a `load` call.
    private var pendingScriptIDs: Set<UUID> = []
    /// Scripts in load order — used to attribute an `inited` event that
    /// arrived without a script id (a script calling `globalThis.lx` /
    /// `window.lx` instead of the per-script `lx` it was handed).
    private var loadOrder: [UUID] = []
    /// Set while a `load` is waiting for scripts to initialize; fires (once)
    /// when every script has reported or the grace period runs out.
    private var loadFinisher: (() -> Void)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RedirectLimitDelegate.shared, delegateQueue: nil)
    }

    // Only meaningful when called on `queue`.
    var contextOnQueue: JSContext? { context }

    func runOnQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Redirect counting for `follow_max` (see `makeRequest`).
    private final class RedirectLimitDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = RedirectLimitDelegate()
        private let lock = NSLock()
        private var remaining: [Int: Int] = [:]

        func setRemaining(_ value: Int?, forTaskIdentifier id: Int) {
            lock.withLock {
                if let value { remaining[id] = value } else { remaining.removeValue(forKey: id) }
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let id = task.taskIdentifier
            let allowed: Bool = lock.withLock {
                guard let left = remaining[id] else { return true }
                if left <= 0 { return false }
                remaining[id] = left - 1
                return true
            }
            completionHandler(allowed ? request : nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            setRemaining(nil, forTaskIdentifier: task.taskIdentifier)
        }
    }

    // MARK: Loading

    /// Evaluates every script into a fresh shared context and waits (up to
    /// `initTimeout`) for their `inited` events.
    func load(scripts: [LxScriptInput], env: String, version: String, initTimeout: TimeInterval = 10) async throws -> LxLoadResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LxLoadResult, Error>) in
            var resumed = false

            func finish(_ result: Result<LxLoadResult, Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            queue.async { [weak self] in
                guard let self else {
                    finish(.failure(LuoxueScriptError.noScript))
                    return
                }

                self.capabilities = [:]
                self.scriptResults = [:]
                self.lastCapturedURL = nil

                let context = JSContext()
                guard let context else {
                    finish(.failure(LuoxueScriptError.notLoaded))
                    return
                }
                context.exceptionHandler = { [weak self] _, exception in
                    let message = exception?.description ?? "unknown script exception"
                    self?.recordScriptError(message)
                }
                self.context = context

                let bridge = LxNativeBridge(engine: self)
                self.bridge = bridge
                context.setObject(bridge, forKeyedSubscript: "__lxBridge" as NSString)
                context.setObject(env, forKeyedSubscript: "__lxEnv" as NSString)
                context.setObject(version, forKeyedSubscript: "__lxVersion" as NSString)

                context.evaluateScript(Self.hostSource)
                context.evaluateScript(Self.zlibPromiseSource)

                // Scripts that have not reported `inited` yet; when the set
                // empties, loading is done without waiting out the grace
                // period.
                self.pendingScriptIDs = Set(scripts.map(\.id))

                Self.log.info("loadScripts called. count=\(scripts.count, privacy: .public)")
                self.loadOrder = scripts.map(\.id)
                for input in scripts {
                    Self.log.info("loading script meta. name=\(input.name, privacy: .public)")
                    self.currentScriptID = input.id
                    self.scriptResults[input.id] = LxScriptResult()

                    // Per-script identity, exactly like the reference app:
                    // globalThis.lx.currentScriptInfo = {…}. Each script is
                    // evaluated through __lxWrapScript with its own `lx` — a
                    // per-script proxy whose `send` stamps every event with
                    // the script's id, so `inited` reported asynchronously
                    // (the common case: sources initialize over the network)
                    // is still attributed to the right source instead of
                    // being silently dropped.
                    let info: [String: Any] = [
                        "name": input.meta["name"] ?? input.name,
                        "description": input.meta["description"] ?? "",
                        "version": input.meta["version"] ?? "",
                        "author": input.meta["author"] ?? "",
                    ]
                    context.setObject(input.id.uuidString, forKeyedSubscript: "__lxScriptID" as NSString)
                    context.setObject(info, forKeyedSubscript: "__lxScriptInfo" as NSString)
                    context.setObject(input.script, forKeyedSubscript: "__lxScriptSource" as NSString)

                    // CommonJS scripts expect `module`/`exports` to exist.
                    context.evaluateScript(Self.modulePreludeSource)
                    context.evaluateScript(Self.scriptWrapperSource)
                    // A script that threw is recorded, but the next one still
                    // loads — one bad file never kills the engine.
                    context.evaluateScript(Self.commonJSAdapterSource)
                }
                self.currentScriptID = nil
                // Host-level shims are idempotent; apply them once after the
                // scripts so per-script pieces cannot re-wrap them.
                context.evaluateScript(Self.hybridBodyWrapperSource)
                context.evaluateScript(Self.cerumusicCompatSource)

                func finishLoading() {
                    for id in self.pendingScriptIDs where self.scriptResults[id]?.error == nil {
                        // Keep the real exception message when there is one;
                        // only scripts that stayed silent get the timeout note.
                        self.scriptResults[id]?.error = "script never reported initialization"
                    }
                    let capabilities = self.capabilities
                    let results = self.scriptResults
                    let handlerCount = self.requestHandlerCountOnQueue()
                    Self.log.info("loadScripts finished. requestHandlers=\(handlerCount, privacy: .public), registeredSources=\(capabilities.keys.sorted().joined(separator: ","), privacy: .public)")
                    finish(.success(LxLoadResult(capabilities: capabilities, scriptResults: results)))
                }

                // As soon as every script has reported `inited`, loading is
                // complete — no need to sit out the whole grace period.
                self.loadFinisher = finishLoading
                if self.pendingScriptIDs.isEmpty { finishLoading() }

                // Grace period for scripts that finish initializing over the
                // network before reporting `inited`.
                self.queue.asyncAfter(deadline: .now() + initTimeout) { [weak self] in
                    guard let self else { return }
                    let finisher = self.loadFinisher
                    self.loadFinisher = nil
                    finisher?()
                }
            }
        }
    }

    private func recordScriptError(_ message: String) {
        guard let id = currentScriptID else { return }
        if scriptResults[id]?.error == nil {
            scriptResults[id]?.error = message
        }
    }

    /// Fires the pending `load` completion once no script is still waiting on
    /// its `inited` event.
    private func maybeFinishLoading() {
        guard pendingScriptIDs.isEmpty else { return }
        let finisher = loadFinisher
        loadFinisher = nil
        finisher?()
    }

    /// `send(EVENT_NAMES.inited, { status, sources })` and friends. Called by
    /// the native bridge, so not private.
    ///
    /// Attribution: `inited` usually arrives asynchronously (most sources
    /// initialize over the network), long after `currentScriptID` has moved
    /// on. The per-script wrapper stamps `send` calls with the script's id
    /// (`fromScriptID`); synchronous sends fall back to `currentScriptID`;
    /// anything that bypassed the wrapper (a script using `window.lx`
    /// directly) is attributed to the oldest script still waiting.
    func handleScriptEvent(_ name: String, payload: JSValue, fromScriptID explicitID: UUID? = nil) {
        guard let object = payload.toObject() as? [String: Any] else { return }
        switch name {
        case "inited":
            let ownerID = explicitID
                ?? currentScriptID
                ?? loadOrder.first { pendingScriptIDs.contains($0) }
            if let status = object["status"] as? Bool, !status {
                if let id = ownerID {
                    if scriptResults[id]?.error == nil {
                        scriptResults[id]?.error = "script reported status: false"
                    }
                    pendingScriptIDs.remove(id)
                    maybeFinishLoading()
                }
                return
            }
            // A script without `sources` has still finished initializing.
            if let id = ownerID {
                pendingScriptIDs.remove(id)
                maybeFinishLoading()
            }
            guard let sources = object["sources"] as? [String: Any] else { return }
            var registered: [String] = []
            for (key, raw) in sources {
                guard let info = raw as? [String: Any] else { continue }
                let qualitys = info["qualitys"] as? [String] ?? []
                capabilities[key] = qualitys
                registered.append(key)
            }
            if let id = ownerID {
                scriptResults[id]?.sources = registered.sorted()
            }
        case "updateAlert", "showConfigView":
            // Informational in this app, like the reference.
            break
        default:
            break
        }
    }

    // MARK: Resolving

    /// Number of registered request handlers (queue-confined read).
    private func requestHandlerCountOnQueue() -> Int {
        guard let context,
              let lx = context.objectForKeyedSubscript("lx"),
              let count = lx.invokeMethod("__handlerCount", withArguments: []),
              count.isNumber else { return 0 }
        return Int(count.toInt32())
    }

    /// Walks every registered handler (in registration order) and every
    /// quality candidate (best first) until one produces a URL. When none
    /// does, the last URL captured from `lx.request` is the fallback — the
    /// reference app's `lastRequestResolvedMusicURL`.
    func resolve(
        source: String,
        musicInfo: [String: Any],
        qualities: [String],
        timeout: TimeInterval = 20
    ) async throws -> LuoxueResolvedMusic {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LuoxueResolvedMusic, Error>) in
            queue.async { [weak self] in
                guard let self, let context = self.context else {
                    continuation.resume(throwing: LuoxueScriptError.notLoaded)
                    return
                }
                let lx = context.objectForKeyedSubscript("lx")
                guard let lx, !lx.isUndefined, !lx.isNull else {
                    continuation.resume(throwing: LuoxueScriptError.notLoaded)
                    return
                }
                let handlerCount = self.requestHandlerCountOnQueue()
                guard handlerCount > 0 else {
                    continuation.resume(throwing: LuoxueScriptError.noRequestHandler)
                    return
                }
                // A fresh resolve starts with a clean capture slate.
                self.lastCapturedURL = nil

                let settled = LuoxueSettlementBox()
                settled.finish = { result in
                    continuation.resume(with: result)
                }

                func attemptNext(handlerIndex: Int, qualityIndex: Int) {
                    guard handlerIndex < handlerCount else {
                        // Every handler failed: the last link the script
                        // fetched is the reference app's final answer.
                        if let captured = self.lastCapturedURL,
                           let url = Self.makeURL(from: captured) {
                            Self.log.info("resolve fallback to captured request url: \(captured.prefix(120), privacy: .public)")
                            settled.succeedURL(captured, url)
                        } else {
                            settled.fail(LuoxueScriptError.noMusicURL)
                        }
                        return
                    }
                    let quality: String
                    if qualityIndex < qualities.count {
                        quality = qualities[qualityIndex]
                    } else if let first = qualities.first {
                        quality = first
                    } else {
                        quality = "128k"
                    }

                    let payload: [String: Any] = [
                        "action": "musicUrl",
                        "source": source,
                        "info": [
                            "type": quality,
                            "musicInfo": musicInfo,
                        ],
                    ]
                    guard let payloadValue = JSValue(object: payload, in: context) else {
                        settled.fail(LuoxueScriptError.noRequestHandler)
                        return
                    }
                    let promise = lx.invokeMethod("__invokeAt", withArguments: [handlerIndex, payloadValue])
                    guard let promise, !promise.isUndefined, !promise.isNull else {
                        // This handler slot is gone; move to the next handler.
                        attemptNext(handlerIndex: handlerIndex + 1, qualityIndex: 0)
                        return
                    }

                    let callbacks = LuoxuePromiseCallbacks()
                    callbacks.onResolve = { value in
                        settled.succeed(value)
                    }
                    callbacks.onReject = { value in
                        let message = LuoxueSettlementBox.errorMessage(from: value)
                        Self.log.error("resolveMusicUrl failed. source=\(source, privacy: .public) handler=\(handlerIndex, privacy: .public) quality=\(quality, privacy: .public) error=\(message, privacy: .public)")
                        // Lower quality first, then the next handler — the
                        // reference app's retryWithLowerQualityIfPossible
                        // followed by "retry with next JS handler".
                        if qualityIndex + 1 < qualities.count {
                            attemptNext(handlerIndex: handlerIndex, qualityIndex: qualityIndex + 1)
                        } else {
                            attemptNext(handlerIndex: handlerIndex + 1, qualityIndex: 0)
                        }
                    }
                    guard let callbacksValue = JSValue(object: callbacks, in: context) else {
                        settled.fail(LuoxueScriptError.noRequestHandler)
                        return
                    }
                    lx.invokeMethod("__then", withArguments: [promise, callbacksValue])
                }

                attemptNext(handlerIndex: 0, qualityIndex: 0)

                self.queue.asyncAfter(deadline: .now() + timeout) { [weak settled] in
                    settled?.fail(LuoxueScriptError.timedOut)
                }
            }
        }
    }

    // MARK: Request helpers (queue-confined)

    func makeRequest(urlValue: JSValue, optionsValue: JSValue) -> URLRequest? {
        guard let urlString = urlValue.isString ? (urlValue.toString() ?? nil) : nil,
              let url = Self.makeURL(from: urlString) else {
            Self.log.error("lx.request invalid URL: \(urlValue.toString() ?? "", privacy: .public)")
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Present as the official LX Music mobile client: many source APIs
        // whitelist (or at least don't block) its user agent.
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                    + "lx-music-mobile/2.12.0 Mobile Safari/605.1.15",
                forHTTPHeaderField: "User-Agent")
        }

        var followMax = 5
        if optionsValue.isObject, let options = optionsValue.toObject() as? [String: Any] {
            if let method = options["method"] as? String, !method.isEmpty {
                request.httpMethod = method.uppercased()
            }
            if let headers = options["headers"] as? [String: Any] {
                for (name, value) in headers {
                    request.setValue(String(describing: value), forHTTPHeaderField: name)
                }
            }
            if let body = options["body"] {
                if let string = body as? String {
                    request.httpBody = Data(string.utf8)
                } else if let number = body as? NSNumber {
                    request.httpBody = Data(number.stringValue.utf8)
                } else if JSONSerialization.isValidJSONObject(body),
                          let data = try? JSONSerialization.data(withJSONObject: body) {
                    request.httpBody = data
                    if request.value(forHTTPHeaderField: "Content-Type") == nil {
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
            if let follow = options["follow_max"] as? Int, follow >= 0 {
                followMax = follow
            }
        }
        request.setValue("\(followMax)", forHTTPHeaderField: "X-Lx-Follow-Max")
        return request
    }

    struct LxHTTPError: Error {
        let message: String
    }

    func performRequest(_ request: URLRequest, completion: @escaping (Result<[String: Any], LxHTTPError>) -> Void) {
        // `follow_max` rides on a private header; the delegate counts down.
        var request = request
        let followMax = Int(request.value(forHTTPHeaderField: "X-Lx-Follow-Max") ?? "") ?? 5
        request.setValue(nil, forHTTPHeaderField: "X-Lx-Follow-Max")

        // The request URL itself is a capture candidate.
        if let urlString = request.url?.absoluteString {
            lastCapturedURL = urlString
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                self?.queue.async {
                    completion(.failure(LxHTTPError(message: error.localizedDescription)))
                }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                self?.queue.async {
                    completion(.failure(LxHTTPError(message: "non-http response")))
                }
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in httpResponse.allHeaderFields {
                headers[String(describing: name).lowercased()] = String(describing: value)
            }

            let body: Any = (data.flatMap { String(data: $0, encoding: .utf8) }) ?? ""
            Self.log.info("lx.request <- status \(httpResponse.statusCode, privacy: .public)")

            self?.queue.async {
                // Any http(s) link inside the body is a capture candidate too
                // ("captured url candidate (from body)") — recorded on the
                // engine queue alongside every other capture.
                if let text = body as? String, let candidate = Self.firstURL(in: text) {
                    self?.lastCapturedURL = candidate
                }
                completion(.success([
                    "statusCode": httpResponse.statusCode,
                    "headers": headers,
                    "body": body,
                ]))
            }
        }
        RedirectLimitDelegate.shared.setRemaining(followMax, forTaskIdentifier: task.taskIdentifier)
        task.resume()
    }

    /// First http(s) URL inside a text body, if any.
    static func firstURL(in text: String) -> String? {
        guard let range = text.range(of: "http", options: .caseInsensitive) else { return nil }
        let rest = text[range.lowerBound...]
        let stop: Set<Character> = [" ", "\"", "'", "<", ">", "\n", "\r", "\t", "\\", ")"]
        var url = Substring(rest.prefix(2048))
        while let last = url.last, stop.contains(last) {
            url = url.dropLast()
        }
        let candidate = String(url)
        guard candidate.count > 8, URL(string: candidate) != nil else { return nil }
        return candidate
    }

    /// 网盘-style resolvers often return links with raw spaces or unencoded
    /// characters, which `URL(string:)` refuses outright. Percent-encode just
    /// the characters that are illegal anywhere in a URL and try again.
    static func makeURL(from string: String) -> URL? {
        if let url = URL(string: string) { return url }
        let allowed = CharacterSet.urlHostAllowed
            .union(.urlPathAllowed)
            .union(.urlQueryAllowed)
            .union(.urlFragmentAllowed)
        guard let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded) else { return nil }
        return url
    }

    // MARK: Shim

    /// The `globalThis.lx` host API every LX Music custom source script
    /// expects, assembled exactly like the reference app: console (with
    /// group/groupEnd), atob/btoa, the host object with EVENT_NAMES /
    /// on / send / request / utils(buffer, zlib) / env / version, then the
    /// per-script pieces (currentScriptInfo injection, CommonJS adapter,
    /// hybrid body wrapper, cerumusic compat, window alias) are layered on
    /// top by `load`.
    private static let hostSource = """
    globalThis.console = (function() {
      var bridge = globalThis.__lxBridge
      var groupDepth = 0
      function format(args) {
        var out = []
        for (var i = 0; i < args.length; i++) {
          var a = args[i]
          try {
            out.push(typeof a === 'string' ? a : JSON.stringify(a))
          } catch (e) {
            out.push(String(a))
          }
        }
        return out.join(' ')
      }
      function emit(level) {
        return function() {
          try { bridge.consoleLog('[' + level + '] ' + Array(groupDepth).join('  ') + format(arguments)) } catch (e) {}
        }
      }
      return {
        log: emit('log'), warn: emit('warn'), error: emit('error'),
        info: emit('info'), debug: emit('debug'), trace: emit('trace'),
        group: function() { groupDepth++ }, groupEnd: function() { if (groupDepth > 0) groupDepth-- },
      }
    })()

    // JavaScriptCore has no atob/btoa.
    globalThis.atob = function(str) {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/='
      var output = ''
      str = String(str).replace(/=+$/, '')
      if (str.length % 4 == 1) {
        throw new Error("'atob' failed: The string to be decoded is not correctly encoded.")
      }
      for (var bc = 0, bs = 0, buffer, i = 0;
           buffer = str.charAt(i++);
           ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4)
             ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
        buffer = chars.indexOf(buffer)
      }
      return output
    }
    globalThis.btoa = function(str) {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/='
      var output = ''
      for (var block, charCode, idx = 0, map = chars;
           str.charAt(idx | 0) || (map = '=', idx % 1);
           output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
        charCode = str.charCodeAt(idx |= 0)
        block = idx % 3 ? block * 256 + charCode : charCode
      }
      return output
    }

    globalThis.lx = (function() {
      var bridge = globalThis.__lxBridge
      var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert', showConfigView: 'showConfigView' }
      var requestHandlers = []

      function toBuffer(value) {
        if (value == null) return []
        if (Array.isArray(value)) return value
        if (typeof value === 'string') {
          var fromString = []
          for (var i = 0; i < value.length; i++) fromString.push(value.charCodeAt(i) & 255)
          return fromString
        }
        if (typeof ArrayBuffer !== 'undefined' &&
            (value instanceof ArrayBuffer || ArrayBuffer.isView(value))) {
          var view = value instanceof ArrayBuffer ? new Uint8Array(value)
            : new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
          var fromView = []
          for (var j = 0; j < view.length; j++) fromView.push(view[j])
          return fromView
        }
        return []
      }

      function makeBuffer(bytes) {
        var arr = bytes.slice()
        arr.toString = function(type) { return bridge.bufferToString(arr, type || 'utf8') }
        return arr
      }

      var utils = {
        buffer: {
          from: function(text, type) {
            return makeBuffer(bridge.bufferFrom(String(text == null ? '' : text), type || 'utf8'))
          },
          bufToString: function(buf, type) {
            return bridge.bufferToString(toBuffer(buf), type || 'utf8')
          },
        },
        zlib: {
          _inflateSync: function(buf) { return bridge.zlibInflate(toBuffer(buf)) },
          _deflateSync: function(buf) { return bridge.zlibDeflate(toBuffer(buf)) },
        },
      }

      return {
        EVENT_NAMES: EVENT_NAMES,
        currentScriptInfo: {},
        on: function(name, handler) {
          if (name === EVENT_NAMES.request && typeof handler === 'function') requestHandlers.push(handler)
        },
        send: function(name, data) {
          bridge.scriptEvent(name, data, null)
        },
        request: function(url, options, callback) {
          bridge.httpRequest(url, options || {}, callback)
        },
        utils: utils,
        env: globalThis.__lxEnv,
        version: globalThis.__lxVersion,
        __handlerCount: function() { return requestHandlers.length },
        __invokeAt: function(index, payload) {
          var handler = requestHandlers[index]
          if (!handler) return Promise.reject(new Error('no request handler registered'))
          try {
            return Promise.resolve(handler(payload))
          } catch (err) {
            return Promise.reject(err)
          }
        },
        __then: function(promise, callbacks) {
          Promise.resolve(promise).then(
            function(value) { callbacks.resolve(value) },
            function(error) { callbacks.reject(error) }
          )
        },
      }
    })()

    window = globalThis
    window.lx = globalThis.lx
    """

    /// Evaluated BEFORE each user script: CommonJS plugins expect `module`
    /// and `exports` to already exist.
    private static let modulePreludeSource = """
    (function() {
      if (!globalThis.module) globalThis.module = { exports: {} }
      globalThis.exports = globalThis.module.exports
    })();
    """

    /// Evaluated IN PLACE OF each user script: hands the script its own `lx`
    /// — a per-script proxy over the shared host API whose `send` stamps the
    /// script's id onto every event, so `inited` reported asynchronously
    /// (after network init) is attributed to the right source. Free `lx`
    /// references inside the script — including inside async callbacks —
    /// resolve to the proxy through the closure scope. `currentScriptInfo`
    /// is the real object (not a JSON string), matching the reference app.
    private static let scriptWrapperSource = """
    (function() {
      var source = globalThis.__lxScriptSource
      if (typeof source !== 'string' || source.length === 0) return
      var info = globalThis.__lxScriptInfo || {}
      var scriptId = globalThis.__lxScriptID || null
      var env = Object.create(globalThis.lx)
      env.currentScriptInfo = info
      globalThis.lx.currentScriptInfo = info
      env.send = function(name, data) {
        globalThis.__lxBridge.scriptEvent(name, data, scriptId)
      }
      new Function('lx', source)(env)
    })()
    """

    /// Evaluated AFTER each user script: adapts CommonJS-style plugins
    /// (`module.exports.musicUrl` + `.sources`) onto the LX protocol, exactly
    /// like the reference app's adapter.
    private static let commonJSAdapterSource = """
    (function() {
      try {
        const exp = globalThis.module && globalThis.module.exports;
        if (!exp || typeof exp.musicUrl !== 'function' || !exp.sources) return;

        const pluginInfo = exp.pluginInfo || {};
        const sources = exp.sources || {};
        const mapped = {};

        for (const id of Object.keys(sources)) {
          const s = sources[id];
          if (!s || typeof s !== 'object') continue;
          const q = Array.isArray(s.qualitys) ? s.qualitys : [];
          mapped[id] = {
            name: (pluginInfo.name ? (pluginInfo.name + ' - ') : '') + (s.name || id),
            type: 'music',
            actions: ['musicUrl'],
            qualitys: q,
          };
        }

        if (Object.keys(mapped).length) {
          lx.send('inited', { sources: mapped });
        }

        lx.on('request', ({ action, source, info }) => {
          if (action !== 'musicUrl') return;
          const quality = info && info.type;
          const musicInfo = (info && info.musicInfo) || {};
          return Promise.resolve(exp.musicUrl(source, musicInfo, quality)).then(res => {
            if (typeof res === 'string') return res;
            // Objects keep their headers ({url, headers}) so the host can
            // attach them to the media requests.
            if (res && typeof res.url === 'string') return res;
            return '';
          });
        });
      } catch (e) {}
    })();
    """

    /// JSON-looking string response bodies become hybrid String objects that
    /// also expose the parsed value (.json/.text/.data/.raw): scripts that
    /// call JSON.parse(body) and scripts that read body.code both work —
    /// the reference app's wrapper, verbatim.
    private static let hybridBodyWrapperSource = """
    (function() {
      if (globalThis.__lxWrapped) return
      globalThis.__lxWrapped = true
      const __nativeRequest = lx.request;
      lx.request = function(url, options, callback) {
        return __nativeRequest(url, options, function(err, resp) {
          try {
            if (!err && resp && typeof resp === 'object' && typeof resp.body === 'string') {
              const raw = resp.body;
              const first = raw.replace(/^\\s+/, '').charAt(0);
              if (first === '{' || first === '[') {
                try {
                  const parsed = JSON.parse(raw);
                  if (parsed && typeof parsed === 'object') {
                    const hybrid = new String(raw);
                    Object.assign(hybrid, parsed);
                    hybrid.raw = raw;
                    hybrid.text = raw;
                    resp.body = hybrid;
                    if (resp.text == null) resp.text = raw;
                    if (resp.json == null) resp.json = parsed;
                    if (resp.data == null) resp.data = parsed;
                  }
                } catch (_) {}
              }
            }
          } catch (_) {}
          callback(err, resp);
        });
      };
    })();
    """

    /// Promise-based request wrapper compatible with cerumusic plugins,
    /// like the reference app.
    private static let cerumusicCompatSource = """
    (function() {
      if (globalThis.__ceruCompat) return
      globalThis.__ceruCompat = true
      globalThis.module = globalThis.module || { exports: {} };
      globalThis.exports = globalThis.module.exports;
      globalThis.cerumusic = globalThis.cerumusic || {};
      globalThis.cerumusic.request = function(url, options) {
        return new Promise((resolve, reject) => {
          try {
            lx.request(url, options || { method: 'GET' }, (err, resp) => {
              if (err) reject(err);
              else resolve(resp);
            });
          } catch (e) { reject(e); }
        });
      };
      globalThis.cerumusic.NoticeCenter = function() {};
    })();
    """

    /// Promise wrappers for zlib, like the reference app.
    private static let zlibPromiseSource = """
    lx.utils.zlib.inflate = function(buf) {
      return new Promise((resolve, reject) => {
        try {
          var res = lx.utils.zlib._inflateSync(buf);
          if (res) resolve(res); else reject(new Error('Inflate failed'));
        } catch(e) { reject(e); }
      });
    };
    lx.utils.zlib.deflate = function(buf) {
      return new Promise((resolve, reject) => {
        try {
          var res = lx.utils.zlib._deflateSync(buf);
          if (res) resolve(res); else reject(new Error('Deflate failed'));
        } catch(e) { reject(e); }
      });
    };
    """
}

// MARK: - Settlement plumbing

/// Guards one-shot continuation resume; all settlements happen on the queue.
final class LuoxueSettlementBox: @unchecked Sendable {
    private var settled = false
    var finish: ((Result<LuoxueResolvedMusic, Error>) -> Void)?

    func succeed(_ value: JSValue) {
        guard !settled else { return }
        settled = true
        if let urlString = Self.urlString(from: value),
           let url = LxScriptEngine.makeURL(from: urlString),
           url.scheme == "http" || url.scheme == "https" {
            finish?(.success(LuoxueResolvedMusic(url: url, headers: Self.headers(from: value))))
        } else {
            let raw = value.isString ? (value.toString() ?? "") : "non-string result"
            finish?(.failure(LuoxueScriptError.invalidURL(raw)))
        }
    }

    /// The captured-URL fallback path: no script headers to carry.
    func succeedURL(_ string: String, _ url: URL) {
        guard !settled else { return }
        settled = true
        finish?(.success(LuoxueResolvedMusic(url: url, headers: [:], fromRequestCapture: true)))
    }

    /// Sources that answer with `{ url, headers: { User-Agent: … } }`: the
    /// headers are required by the file host (网盘 links 403 without them).
    /// A plain string result (the common case) carries none.
    private static func headers(from value: JSValue) -> [String: String] {
        guard value.isObject else { return [:] }
        guard let raw = value.objectForKeyedSubscript("headers"), raw.isObject,
              let object = raw.toObject() as? [String: Any] else { return [:] }
        var parsed: [String: String] = [:]
        for (name, item) in object where item is String {
            parsed[name] = (item as? String) ?? ""
        }
        return parsed
    }

    func fail(_ error: any Error) {
        guard !settled else { return }
        settled = true
        finish?(.failure(error))
    }

    private static func urlString(from value: JSValue) -> String? {
        if value.isString {
            let string = (value.toString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        if value.isObject, let url = value.objectForKeyedSubscript("url"), url.isString {
            return url.toString() ?? nil
        }
        return nil
    }

    static func errorMessage(from value: JSValue) -> String {
        if value.isString { return value.toString() ?? "" }
        if let message = value.objectForKeyedSubscript("message"), message.isString {
            return message.toString() ?? ""
        }
        return value.toString() ?? ""
    }
}

final class LuoxuePromiseCallbacks: NSObject, LxPromiseExports {
    var onResolve: ((JSValue) -> Void)?
    var onReject: ((JSValue) -> Void)?

    func resolve(_ value: JSValue) { onResolve?(value) }
    func reject(_ error: JSValue) { onReject?(error) }
}

// MARK: - Buffers

/// Byte-array buffer helpers behind `lx.utils.buffer`.
enum LxBuffer {
    static func bytes(from value: JSValue) -> [UInt8] {
        if value.isArray {
            let array = value.toArray() as? [Any] ?? []
            return array.compactMap { ($0 as? NSNumber)?.uint8Value }
        }
        if value.isString {
            return Array((value.toString() ?? "").utf8)
        }
        return []
    }

    static func bytes(fromString string: String, encoding: String) -> [UInt8] {
        switch encoding.lowercased() {
        case "base64":
            guard let data = Data(base64Encoded: string) else { return [] }
            return [UInt8](data)
        case "hex":
            return hexToBytes(string)
        default:
            return Array(string.utf8)
        }
    }

    static func string(fromBytes bytes: [UInt8], encoding: String) -> String {
        switch encoding.lowercased() {
        case "base64":
            return Data(bytes).base64EncodedString()
        case "hex":
            return bytesToHex(bytes)
        default:
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func hexToBytes(_ string: String) -> [UInt8] {
        let characters = Array(string)
        guard characters.count % 2 == 0 else { return [] }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return [] }
            bytes.append(byte)
        }
        return bytes
    }

    private static func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - zlib

/// `lx.utils.zlib` native side. Apple's `COMPRESSION_ZLIB` is raw DEFLATE
/// (RFC 1951); zlib-wrapped input (RFC 1950) carries a 2-byte header that is
/// skipped on the fallback attempt.
enum LxZlib {
    static func inflate(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        if let out = rawInflate(data) { return out }
        if data.count > 2, data[0] == 0x78, let out = rawInflate(Array(data[2...])) { return out }
        return []
    }

    static func deflate(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        let capacity = data.count + data.count / 2 + 256
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                compression_encode_buffer(
                    destinationBuffer.baseAddress!, destinationBuffer.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return [] }
        return Array(destination[0..<written])
    }

    private static func rawInflate(_ source: [UInt8]) -> [UInt8]? {
        guard !source.isEmpty else { return nil }
        let capacity = max(source.count * 8, 64 * 1024)
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                compression_decode_buffer(
                    destinationBuffer.baseAddress!, destinationBuffer.count,
                    sourceBuffer.baseAddress!, sourceBuffer.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Array(destination[0..<written])
    }
}
