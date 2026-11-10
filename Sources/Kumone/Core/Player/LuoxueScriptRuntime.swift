import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto
import Security
import os

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

/// A resolved stream: the URL plus any headers the server insists on.
/// 网盘 sources often answer with `{ url, headers }` — the link only plays
/// when those headers (User-Agent / Referer / Cookie) ride along.
struct LuoxueResolvedMusic: Sendable {
    let url: URL
    let headers: [String: String]
}

// MARK: - JSExport bridges

/// Native surface the Luoxue (LX Music) user script talks to. Every method is
/// invoked by JavaScriptCore on the runtime's serial queue.
@objc protocol LuoxueBridgeExports: JSExport {
    // Console sink behind the shim's `console.log/warn/error/...`.
    func consoleLog(_ message: JSValue)
    // HTTP request primitive behind `lx.request(url, options, callback)`.
    func httpRequest(_ url: JSValue, _ options: JSValue, _ callback: JSValue)
    // Lifecycle events sent by the script via `lx.send(EVENT_NAMES.inited, ...)`.
    func scriptInited(_ payload: JSValue)
    func scriptUpdateAlert(_ payload: JSValue)
    // Buffers.
    func bufferFrom(_ text: JSValue, _ type: JSValue) -> JSValue
    func bufferToString(_ buffer: JSValue, _ type: JSValue) -> JSValue
    // Crypto helpers mirroring the LX Music `utils.crypto` surface.
    func md5(_ text: JSValue) -> JSValue
    func randomBytes(_ size: JSValue) -> JSValue
    func aesEncrypt(_ data: JSValue, _ mode: JSValue, _ key: JSValue, _ iv: JSValue) -> JSValue
    func aesDecrypt(_ data: JSValue, _ mode: JSValue, _ key: JSValue, _ iv: JSValue) -> JSValue
    func rsaEncrypt(_ data: JSValue, _ key: JSValue) -> JSValue
    func rsaDecrypt(_ data: JSValue, _ key: JSValue) -> JSValue
}

/// Promise settlement callbacks handed to the script's handler result.
@objc protocol LuoxuePromiseExports: JSExport {
    func resolve(_ value: JSValue)
    func reject(_ error: JSValue)
}

/// Wraps a `JSValue` so it can be captured by `@Sendable` closures; the value
/// itself is only ever touched on the runtime queue.
final class LuoxueJSValueBox: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

final class LuoxueNativeBridge: NSObject, LuoxueBridgeExports {
    private weak var runtime: LuoxueScriptRuntime?

    init(runtime: LuoxueScriptRuntime) {
        self.runtime = runtime
        super.init()
    }

    // MARK: Console

    private static let consoleLog = Logger(subsystem: "sb.moe.kumone", category: "lx-console")

    func consoleLog(_ message: JSValue) {
        let text = message.toString() ?? ""
        Self.consoleLog.info("\(text, privacy: .public)")
    }

    // MARK: HTTP

    func httpRequest(_ url: JSValue, _ options: JSValue, _ callback: JSValue) {
        guard let runtime = runtime else { return }
        let request = runtime.makeRequest(urlValue: url, optionsValue: options)
        let callbackBox = LuoxueJSValueBox(callback)
        guard let request else {
            runtime.runOnQueue { [weak self] in
                self?.invokeCallback(callbackBox, error: "invalid request")
            }
            return
        }
        runtime.performRequest(request) { [weak runtime] result in
            runtime?.runOnQueue { [weak self] in
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
        guard let runtime = runtime, let context = runtime.contextOnQueue else { return }
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

    func scriptInited(_ payload: JSValue) {
        runtime?.handleScriptInited(payload)
    }

    func scriptUpdateAlert(_ payload: JSValue) {
        // Update notices from the script are informational only.
    }

    // MARK: Buffers

    func bufferFrom(_ text: JSValue, _ type: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let string = text.isString ? (text.toString() ?? "") : ""
        let typeString = type.isString ? (type.toString() ?? "utf8") : "utf8"
        let bytes = LuoxueCrypto.bytes(fromString: string, encoding: typeString)
        return JSValue(object: bytes, in: context) ?? JSValue(nullIn: context)
    }

    func bufferToString(_ buffer: JSValue, _ type: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let bytes = runtime.bytes(from: buffer)
        let typeString = type.isString ? (type.toString() ?? "utf8") : "utf8"
        let string = LuoxueCrypto.string(fromBytes: bytes, encoding: typeString)
        return JSValue(object: string, in: context) ?? JSValue(nullIn: context)
    }

    // MARK: Crypto

    func md5(_ text: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let digest = LuoxueCrypto.md5Hex(text.isString ? (text.toString() ?? "") : "")
        return JSValue(object: digest, in: context) ?? JSValue(nullIn: context)
    }

    func randomBytes(_ size: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let count = size.isNumber ? Int(size.toInt32()) : 0
        return JSValue(object: LuoxueCrypto.randomBytes(count), in: context) ?? JSValue(nullIn: context)
    }

    func aesEncrypt(_ data: JSValue, _ mode: JSValue, _ key: JSValue, _ iv: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let modeString = mode.isString ? (mode.toString() ?? "") : ""
        let output = LuoxueCrypto.aesCrypt(
            operation: CCOperation(kCCEncrypt),
            data: runtime.bytes(from: data),
            mode: modeString,
            key: runtime.bytes(from: key),
            iv: runtime.bytes(from: iv)
        )
        return JSValue(object: output, in: context) ?? JSValue(nullIn: context)
    }

    func aesDecrypt(_ data: JSValue, _ mode: JSValue, _ key: JSValue, _ iv: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let modeString = mode.isString ? (mode.toString() ?? "") : ""
        let output = LuoxueCrypto.aesCrypt(
            operation: CCOperation(kCCDecrypt),
            data: runtime.bytes(from: data),
            mode: modeString,
            key: runtime.bytes(from: key),
            iv: runtime.bytes(from: iv)
        )
        return JSValue(object: output, in: context) ?? JSValue(nullIn: context)
    }

    func rsaEncrypt(_ data: JSValue, _ key: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let pem = key.isString ? (key.toString() ?? "") : ""
        let output = LuoxueCrypto.rsaCrypt(
            operation: CCOperation(kCCEncrypt),
            data: runtime.bytes(from: data),
            pem: pem
        )
        return JSValue(object: output, in: context) ?? JSValue(nullIn: context)
    }

    func rsaDecrypt(_ data: JSValue, _ key: JSValue) -> JSValue {
        guard let runtime = runtime, let context = runtime.contextOnQueue else {
            return JSValue(undefinedIn: JSContext())
        }
        let pem = key.isString ? (key.toString() ?? "") : ""
        let output = LuoxueCrypto.rsaCrypt(
            operation: CCOperation(kCCDecrypt),
            data: runtime.bytes(from: data),
            pem: pem
        )
        return JSValue(object: output, in: context) ?? JSValue(nullIn: context)
    }
}

// MARK: - Runtime

/// Runs a Luoxue (LX Music) custom source user script in a JavaScriptCore
/// context and bridges its `musicUrl` action to Swift.
///
/// Thread model: the `JSContext` (and every `JSValue` derived from it) is
/// confined to `queue`. Public methods are async and hop onto that queue,
/// never passing `JSValue` across the boundary — only plain Sendable values.
final class LuoxueScriptRuntime {
    struct Capability {
        let name: String
        let actions: [String]
        let qualitys: [String]
    }

    private let queue = DispatchQueue(label: "sb.moe.kun.luoxue", qos: .userInitiated)
    private let session: URLSession
    private var context: JSContext?
    private var bridge: LuoxueNativeBridge?
    private var capabilities: [String: Capability] = [:]
    private var initErrorMessage: String?
    private var scriptFailedMessage: String?

    /// Set when `scriptInited` arrives; observed on the runtime queue.
    var onInited: (() -> Void)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    // Only meaningful when called on `queue`.
    var contextOnQueue: JSContext? { context }

    func runOnQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    // MARK: Loading

    /// One `@field value` entry from a script's leading comment header.
    private static func scriptHeaderField(_ field: String, in script: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "@\(field)\\s+([^\\r\\n*]+)"),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else { return nil }
        let value = script[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Evaluates the script and waits (briefly) for its `inited` event.
    func load(script: String, env: String, version: String) async throws -> [String: Capability] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Capability], Error>) in
            var resumed = false

            func finish(_ result: Result<[String: Capability], Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            onInited = nil

            queue.async { [weak self] in
                guard let self else {
                    finish(.failure(LuoxueScriptError.noScript))
                    return
                }

                self.capabilities = [:]
                self.initErrorMessage = nil
                self.scriptFailedMessage = nil

                let context = JSContext()
                guard let context else {
                    finish(.failure(LuoxueScriptError.notLoaded))
                    return
                }
                context.exceptionHandler = { [weak self] _, exception in
                    let message = exception?.description ?? "unknown script exception"
                    self?.scriptFailedMessage = message
                }
                self.context = context

                let bridge = LuoxueNativeBridge(runtime: self)
                self.bridge = bridge
                context.setObject(bridge, forKeyedSubscript: "__lxBridge" as NSString)
                context.setObject(env, forKeyedSubscript: "__lxEnv" as NSString)
                context.setObject(version, forKeyedSubscript: "__lxVersion" as NSString)
                // `lx.currentScriptInfo` — some scripts read their own header
                // metadata (e.g. for integrity checks) at init time.
                context.setObject(Self.scriptHeaderField("name", in: script) ?? "", forKeyedSubscript: "__lxScriptName" as NSString)
                context.setObject(Self.scriptHeaderField("description", in: script) ?? "", forKeyedSubscript: "__lxScriptDescription" as NSString)
                context.setObject(Self.scriptHeaderField("version", in: script) ?? "", forKeyedSubscript: "__lxScriptVersion" as NSString)
                context.setObject(Self.scriptHeaderField("author", in: script) ?? "", forKeyedSubscript: "__lxScriptAuthor" as NSString)

                context.evaluateScript(Self.shimSource)

                // User script: evaluate and surface any thrown exception.
                context.evaluateScript(script)
                if let failure = self.scriptFailedMessage {
                    self.context = nil
                    self.bridge = nil
                    finish(.failure(LuoxueScriptError.scriptThrew(failure)))
                    return
                }
                // CommonJS-style plugins are adapted onto the LX protocol
                // after the script body ran and had a chance to fill
                // module.exports.
                context.evaluateScript(Self.commonJSAdapterSource)

                // Give asynchronously-initializing scripts a grace period
                // before declaring the script dead. Many sources run a
                // network version check in their init before reporting
                // `inited`; on real-world networks that regularly takes more
                // than a couple of seconds, so the deadline is generous.
                self.queue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    guard let self else { return }
                    let inited = !self.capabilities.isEmpty
                    let failure = self.initErrorMessage
                    self.context = nil
                    self.bridge = nil
                    self.onInited = nil
                    if inited {
                        finish(.success(self.capabilities))
                    } else if let failure {
                        finish(.failure(LuoxueScriptError.scriptInitFailed(failure)))
                    } else {
                        finish(.failure(LuoxueScriptError.scriptInitFailed("script never reported initialization")))
                    }
                }
            }
        }
    }

    /// Called (on the queue) when the script sends `EVENT_NAMES.inited`.
    func handleScriptInited(_ payload: JSValue) {
        guard let object = payload.toObject() as? [String: Any] else { return }
        if let status = object["status"] as? Bool, !status {
            initErrorMessage = "script reported status: false"
            onInited?()
            return
        }
        guard let sources = object["sources"] as? [String: Any] else {
            initErrorMessage = "inited payload has no sources"
            onInited?()
            return
        }
        var parsed: [String: Capability] = [:]
        for (key, raw) in sources {
            guard let info = raw as? [String: Any] else { continue }
            let name = info["name"] as? String ?? key
            let actions = info["actions"] as? [String] ?? []
            let qualitys = info["qualitys"] as? [String] ?? []
            parsed[key] = Capability(name: name, actions: actions, qualitys: qualitys)
        }
        capabilities = parsed
        onInited?()
    }

    // MARK: Resolving

    func capabilities() async -> [String: Capability] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Capability], Never>) in
            queue.async { [weak self] in
                continuation.resume(returning: self?.capabilities ?? [:])
            }
        }
    }

    func resolveMusicURL(source: String, songID: Int, quality: String, timeout: TimeInterval = 20) async throws -> LuoxueResolvedMusic {
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

                let payload: [String: Any] = [
                    "source": source,
                    "action": "musicUrl",
                    "info": [
                        "type": quality,
                        // LX Music scripts read the id from `songmid`, `id` or
                        // `mid` — a lone `songId` key is invisible to them and
                        // every request failed with "缺少歌曲ID".
                        "musicInfo": [
                            "songmid": String(songID),
                            "id": String(songID),
                            "songId": songID,
                            "source": source,
                        ],
                    ],
                ]
                guard let payloadValue = JSValue(object: payload, in: context) else {
                    continuation.resume(throwing: LuoxueScriptError.noRequestHandler)
                    return
                }
                let promise = lx.invokeMethod("__invokeRequest", withArguments: [payloadValue])
                guard let promise, !promise.isUndefined, !promise.isNull else {
                    continuation.resume(throwing: LuoxueScriptError.noRequestHandler)
                    return
                }

                let settled = LuoxueSettlementBox()
                settled.finish = { result in
                    // Always invoked on the runtime queue.
                    continuation.resume(with: result)
                }
                let callbacks = LuoxuePromiseCallbacks()
                callbacks.onResolve = { value in
                    settled.succeed(value)
                }
                callbacks.onReject = { value in
                    settled.fail(LuoxueScriptError.scriptThrew(LuoxueSettlementBox.errorMessage(from: value)))
                }
                guard let callbacksValue = JSValue(object: callbacks, in: context) else {
                    continuation.resume(throwing: LuoxueScriptError.noRequestHandler)
                    return
                }
                lx.invokeMethod("__then", withArguments: [promise, callbacksValue])

                queue.asyncAfter(deadline: .now() + timeout) { [weak settled] in
                    settled?.fail(LuoxueScriptError.timedOut)
                }
            }
        }
    }

    // MARK: Request helpers (queue-confined)

    func bytes(from value: JSValue) -> [UInt8] {
        if value.isArray {
            let array = value.toArray() as? [Any] ?? []
            return array.compactMap { ($0 as? NSNumber)?.uint8Value }
        }
        if value.isString {
            return Array((value.toString() ?? "").utf8)
        }
        return []
    }

    func makeRequest(urlValue: JSValue, optionsValue: JSValue) -> URLRequest? {
        guard let urlString = urlValue.isString ? (urlValue.toString() ?? nil) : nil,
              let url = URL(string: urlString) else { return nil }
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
        }
        return request
    }

    /// Failure payload for `performRequest` (plain `String` is not an `Error`).
    struct LuoxueHTTPError: Error {
        let message: String
    }

    func performRequest(_ request: URLRequest, completion: @escaping (Result<[String: Any], LuoxueHTTPError>) -> Void) {
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(LuoxueHTTPError(message: error.localizedDescription)))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(LuoxueHTTPError(message: "non-http response")))
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in httpResponse.allHeaderFields {
                headers[String(describing: name).lowercased()] = String(describing: value)
            }

            // Body is always the raw string: the JS shim wraps it into a
            // hybrid String that also exposes the parsed JSON (.json/.text),
            // which is what LX scripts expect either way.
            let body: Any = (data.flatMap { String(data: $0, encoding: .utf8) }) ?? ""
            completion(.success([
                "statusCode": httpResponse.statusCode,
                "headers": headers,
                "body": body,
            ]))
        }
        task.resume()
    }

    // MARK: Shim

    /// The `globalThis.lx` host API every LX Music custom source script expects.
    ///
    /// `console` is defined too: JavaScriptCore provides none, and most
    /// user scripts call `console.log` during initialization — without it
    /// the script's last line throws a ReferenceError and the source never
    /// reaches "ready".
    private static let shimSource = """
    globalThis.console = (function() {
      var bridge = globalThis.__lxBridge
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
          try { bridge.consoleLog('[' + level + '] ' + format(arguments)) } catch (e) {}
        }
      }
      return { log: emit('log'), warn: emit('warn'), error: emit('error'),
               info: emit('info'), debug: emit('debug'), trace: emit('trace') }
    })()

    globalThis.lx = (function() {
      var bridge = globalThis.__lxBridge
      var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' }
      var requestHandler = null

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
        crypto: {
          md5: function(text) { return bridge.md5(String(text == null ? '' : text)) },
          randomBytes: function(size) { return makeBuffer(bridge.randomBytes(Number(size) || 0)) },
          aesEncrypt: function(data, mode, key, iv) {
            return makeBuffer(bridge.aesEncrypt(toBuffer(data), String(mode || ''), toBuffer(key), toBuffer(iv)))
          },
          aesDecrypt: function(data, mode, key, iv) {
            return makeBuffer(bridge.aesDecrypt(toBuffer(data), String(mode || ''), toBuffer(key), toBuffer(iv)))
          },
          rsaEncrypt: function(data, key) {
            return makeBuffer(bridge.rsaEncrypt(toBuffer(data), String(key || '')))
          },
          rsaDecrypt: function(data, key) {
            return makeBuffer(bridge.rsaDecrypt(toBuffer(data), String(key || '')))
          },
        },
      }

      return {
        EVENT_NAMES: EVENT_NAMES,
        currentScriptInfo: {
          name: globalThis.__lxScriptName || '',
          description: globalThis.__lxScriptDescription || '',
          version: globalThis.__lxScriptVersion || '',
          author: globalThis.__lxScriptAuthor || '',
        },
        on: function(name, handler) {
          if (name === EVENT_NAMES.request && typeof handler === 'function') requestHandler = handler
        },
        send: function(name, data) {
          if (name === EVENT_NAMES.inited) bridge.scriptInited(data)
          else if (name === EVENT_NAMES.updateAlert) bridge.scriptUpdateAlert(data)
        },
        request: function(url, options, callback) {
          bridge.httpRequest(url, options || {}, callback)
        },
        utils: utils,
        env: globalThis.__lxEnv,
        version: globalThis.__lxVersion,
        __invokeRequest: function(payload) {
          if (!requestHandler) return Promise.reject(new Error('no request handler registered'))
          try {
            return Promise.resolve(requestHandler(payload))
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

    // --- Compatibility layer (modeled on the reference implementations) ---

    // Some scripts address the global object as `window`.
    globalThis.window = globalThis
    globalThis.window.lx = globalThis.lx

    // JavaScriptCore has no atob/btoa.
    if (typeof globalThis.atob !== 'function') {
      globalThis.atob = function(str) {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/='
        var output = ''
        str = String(str).replace(/=+$/, '')
        for (var bc = 0, bs = 0, buffer, i = 0;
             buffer = str.charAt(i++);
             ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4)
               ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
          buffer = chars.indexOf(buffer)
        }
        return output
      }
    }
    if (typeof globalThis.btoa !== 'function') {
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
    }

    // JSON-looking string response bodies become hybrid String objects that
    // also expose the parsed value (.json/.text/.data/.raw): scripts that
    // call JSON.parse(body) and scripts that read body.code both work.
    globalThis.__lxNativeRequest = globalThis.lx.request
    globalThis.lx.request = function(url, options, callback) {
      return globalThis.__lxNativeRequest(url, options || {}, function(err, resp) {
        try {
          if (!err && resp && typeof resp === 'object' && typeof resp.body === 'string') {
            var raw = resp.body
            var first = raw.replace(/^\\s+/, '').charAt(0)
            if (first === '{' || first === '[') {
              try {
                var parsed = JSON.parse(raw)
                if (parsed && typeof parsed === 'object') {
                  var hybrid = new String(raw)
                  Object.assign(hybrid, parsed)
                  hybrid.raw = raw
                  hybrid.text = raw
                  resp.body = hybrid
                  if (resp.text == null) resp.text = raw
                  if (resp.json == null) resp.json = parsed
                  if (resp.data == null) resp.data = parsed
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
        callback(err, resp)
      })
    }

    // CommonJS module globals, for plugin scripts written as
    // `module.exports = { sources, musicUrl }` instead of the LX protocol.
    globalThis.module = globalThis.module || { exports: {} }
    globalThis.exports = globalThis.module.exports
    """
}

/// Evaluated AFTER the user script: adapts CommonJS-style plugins
/// (`module.exports.musicUrl` + `.sources`) onto the LX protocol so they
/// behave like ordinary custom sources.
private extension LuoxueScriptRuntime {
    static let commonJSAdapterSource = """
    (function() {
      try {
        var exp = globalThis.module && globalThis.module.exports
        if (!exp || typeof exp.musicUrl !== 'function' || !exp.sources) return

        var pluginInfo = exp.pluginInfo || {}
        var sources = exp.sources || {}
        var mapped = {}

        for (var id of Object.keys(sources)) {
          var s = sources[id]
          if (!s || typeof s !== 'object') continue
          var q = Array.isArray(s.qualitys) ? s.qualitys : []
          mapped[id] = {
            name: (pluginInfo.name ? (pluginInfo.name + ' - ') : '') + (s.name || id),
            type: 'music',
            actions: ['musicUrl'],
            qualitys: q,
          }
        }

        if (Object.keys(mapped).length) {
          globalThis.lx.send('inited', { sources: mapped })
          globalThis.lx.on('request', function(payload) {
            if (!payload || payload.action !== 'musicUrl') return
            var quality = payload.info && payload.info.type
            var musicInfo = (payload.info && payload.info.musicInfo) || {}
            return Promise.resolve(exp.musicUrl(payload.source, musicInfo, quality)).then(function(res) {
              if (typeof res === 'string') return res
              // Objects keep their headers ({url, headers}) so the host can
              // attach them to the media requests.
              if (res && typeof res.url === 'string') return res
              return ''
            })
          })
        }
      } catch (e) {}
    })()
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
           let url = Self.makeURL(from: urlString),
           url.scheme == "http" || url.scheme == "https" {
            finish?(.success(LuoxueResolvedMusic(url: url, headers: Self.headers(from: value))))
        } else {
            let raw = value.isString ? (value.toString() ?? "") : "non-string result"
            finish?(.failure(LuoxueScriptError.invalidURL(raw)))
        }
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

    /// 网盘-style resolvers often return links with raw spaces or unencoded
    /// characters, which `URL(string:)` refuses outright. Percent-encode just
    /// the characters that are illegal anywhere in a URL and try again.
    private static func makeURL(from string: String) -> URL? {
        if let url = URL(string: string) { return url }
        let allowed = CharacterSet.urlHostAllowed
            .union(.urlPathAllowed)
            .union(.urlQueryAllowed)
            .union(.urlFragmentAllowed)
        guard let encoded = string.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded) else { return nil }
        return url
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

final class LuoxuePromiseCallbacks: NSObject, LuoxuePromiseExports {
    var onResolve: ((JSValue) -> Void)?
    var onReject: ((JSValue) -> Void)?

    func resolve(_ value: JSValue) { onResolve?(value) }
    func reject(_ error: JSValue) { onReject?(error) }
}

// MARK: - Crypto

/// Native implementations of the helpers LX Music scripts use from `lx.utils`.
enum LuoxueCrypto {
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

    static func md5Hex(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return status == errSecSuccess ? bytes : []
    }

    static func aesCrypt(
        operation: CCOperation,
        data: [UInt8],
        mode: String,
        key: [UInt8],
        iv: [UInt8]
    ) -> [UInt8] {
        // Mode strings look like "aes-128-cbc" / "aes-256-ecb".
        let parts = mode.lowercased().split(separator: "-")
        var keyLength = 16
        if let bitsPart = parts.compactMap({ Int($0) }).first(where: { $0 >= 128 && $0 <= 256 }) {
            keyLength = bitsPart / 8
        }
        let useECB = parts.contains("ecb")

        var keyBytes = [UInt8](repeating: 0, count: keyLength)
        if !key.isEmpty {
            for index in 0..<min(key.count, keyLength) { keyBytes[index] = key[index] }
        }
        var ivBytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        if !useECB, !iv.isEmpty {
            for index in 0..<min(iv.count, kCCBlockSizeAES128) { ivBytes[index] = iv[index] }
        }

        var outputLength = 0
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128 * 2)
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding | (useECB ? kCCOptionECBMode : 0)),
            keyBytes,
            keyLength,
            useECB ? nil : ivBytes,
            data.isEmpty ? nil : data,
            data.count,
            &output,
            output.count,
            &outputLength
        )
        guard status == kCCSuccess else { return [] }
        return Array(output[0..<outputLength])
    }

    static func rsaCrypt(operation: CCOperation, data: [UInt8], pem: String) -> [UInt8] {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let keyData = Data(base64Encoded: base64), !keyData.isEmpty else { return [] }

        let isDecrypt = operation == CCOperation(kCCDecrypt)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: isDecrypt ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
        ]
        var cfError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &cfError) else {
            return []
        }
        let algorithm: SecKeyAlgorithm = .rsaEncryptionPKCS1
        var result: CFData?
        if isDecrypt {
            result = SecKeyCreateDecryptedData(key, algorithm, Data(data) as CFData, &cfError)
        } else {
            result = SecKeyCreateEncryptedData(key, algorithm, Data(data) as CFData, &cfError)
        }
        guard let result else { return [] }
        return [UInt8](result as Data)
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
