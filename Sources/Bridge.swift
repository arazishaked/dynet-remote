import Foundation
import Network
import UIKit
import WebKit
import UniformTypeIdentifiers
 
// Persistent raw-TCP link to the PDEG (physical DyNet frames + live bus traffic).
final class DyNetLink {
    private var conn: NWConnection?
    private var host = ""
    private var port: UInt16 = 0
    private var connected = false
    private var buf = Data()
    private let lock = NSLock()
    private let q = DispatchQueue(label: "dynet.tcp")
 
    @discardableResult
    func open(_ h: String, _ p: UInt16) -> Bool {
        lock.lock(); let same = connected && h == host && p == port; lock.unlock()
        if same { return true }
        close()
        guard let nwPort = NWEndpoint.Port(rawValue: p) else { return false }
        // TCP keepalive keeps the link alive through NAT/router idle timeouts (important on external/cellular)
        // and detects a dropped connection quickly instead of hanging.
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = true
        tcpOpts.keepaliveIdle = 15
        tcpOpts.keepaliveInterval = 8
        tcpOpts.keepaliveCount = 3
        tcpOpts.connectionTimeout = 8
        tcpOpts.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOpts)
        let c = NWConnection(host: NWEndpoint.Host(h), port: nwPort, using: params)
        host = h; port = p; conn = c
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.lock.lock(); self.connected = true; self.lock.unlock()
                ok = true; sem.signal(); self.receive(c)
            case .failed, .cancelled:
                self.lock.lock(); self.connected = false; self.lock.unlock()
                sem.signal()
            default: break
            }
        }
        c.start(queue: q)
        _ = sem.wait(timeout: .now() + 5)
        return ok
    }
 
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.lock.lock(); self.buf.append(d); self.lock.unlock()
            }
            if isComplete || err != nil {
                self.lock.lock(); self.connected = false; self.lock.unlock()
                return
            }
            self.receive(c)
        }
    }
 
    func send(_ data: Data, _ h: String, _ p: UInt16) throws {
        if !open(h, p) { throw NSError(domain: "tcp", code: 1, userInfo: [NSLocalizedDescriptionKey: "no connection"]) }
        let sem = DispatchSemaphore(value: 0)
        var sendErr: Error?
        conn?.send(content: data, completion: .contentProcessed { e in sendErr = e; sem.signal() })
        _ = sem.wait(timeout: .now() + 3)
        if let e = sendErr { throw e }
    }
 
    func poll(_ wait: Double) -> [String: Any] {
        let end = Date().addingTimeInterval(wait)
        while Date() < end {
            lock.lock(); let have = !buf.isEmpty; lock.unlock()
            if have { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock(); let out = buf; buf = Data(); let con = connected; lock.unlock()
        return ["b64": out.base64EncodedString(), "state": con ? "on" : "off"]
    }
 
    func close() {
        conn?.cancel(); conn = nil
        lock.lock(); connected = false; buf = Data(); lock.unlock()
    }
}
 
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var webView: WKWebView?
    private let link = DyNetLink()
    private let cm = DyNetLink()          // second TCP link, dedicated to the CoolMaster (ASCII protocol)
    private let work = DispatchQueue(label: "dynet.work", attributes: .concurrent)
 
    // ---- settings + files live in the app's Documents folder ----
    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var kvURL: URL { docs.appendingPathComponent("kv.json") }
 
    static func kvJSON() -> String {
        guard let data = try? Data(contentsOf: kvURL),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return "{}" }
        return s
    }
    private func loadKV() -> [String: String] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: Bridge.kvURL))) as? [String: String] ?? [:]
    }
    private func saveKV(_ kv: [String: String]) {
        if let d = try? JSONSerialization.data(withJSONObject: kv) { try? d.write(to: Bridge.kvURL) }
    }
 
    // ---- message handler (runs on main; heavy work is dispatched off it) ----
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let m = message.body as? [String: Any], let kind = m["kind"] as? String else {
            replyHandler(["error": "bad message"], nil); return
        }
        if kind == "pick" || kind == "saveFile" || kind == "open" {
            handleUI(kind, m, replyHandler)       // these need the main thread / a view controller
            return
        }
        work.async { [weak self] in
            let res = self?.handle(kind, m) ?? ["error": "gone"]
            DispatchQueue.main.async { replyHandler(res, nil) }
        }
    }
 
    private func handle(_ kind: String, _ m: [String: Any]) -> [String: Any] {
        switch kind {
        case "http":    return httpRequest(m)
        case "tcpOpen":
            let ok = link.open(m["host"] as? String ?? "", UInt16(intOf(m["port"]) ?? 95))
            return ok ? ["ok": true] : ["error": "connect failed"]
        case "tcpSend":
            do {
                try link.send(Data(base64Encoded: m["b64"] as? String ?? "") ?? Data(),
                              m["host"] as? String ?? "", UInt16(intOf(m["port"]) ?? 95))
                return ["ok": true]
            } catch { return ["error": "\(error.localizedDescription)"] }
        case "tcpPoll": return link.poll(m["wait"] as? Double ?? 10)
        case "tcpClose": link.close(); return ["ok": true]
        // ---- CoolMaster (second TCP link, ASCII line protocol) ----
        case "cmOpen":
            let ok = cm.open(m["host"] as? String ?? "", UInt16(intOf(m["port"]) ?? 10102))
            return ok ? ["ok": true] : ["error": "connect failed"]
        case "cmSend":
            do {
                try cm.send(Data(base64Encoded: m["b64"] as? String ?? "") ?? Data(),
                            m["host"] as? String ?? "", UInt16(intOf(m["port"]) ?? 10102))
                return ["ok": true]
            } catch { return ["error": "\(error.localizedDescription)"] }
        case "cmPoll": return cm.poll(m["wait"] as? Double ?? 2)
        case "cmClose": cm.close(); return ["ok": true]
        case "appUpdate": WebApp.sync(into: webView); return ["ok": true]   // re-fetch the hosted UI; reloads if newer
        case "kvset":
            var kv = loadKV()
            let key = m["key"] as? String ?? ""
            if let v = m["value"] as? String { kv[key] = v } else { kv.removeValue(forKey: key) }
            saveKV(kv); return ["ok": true]
        case "filePut":
            if let b64 = m["b64"] as? String, let d = Data(base64Encoded: b64),
               let name = m["name"] as? String {
                try? d.write(to: Bridge.docs.appendingPathComponent(name + ".bin"))
            }
            return ["ok": true]
        case "fileGet":
            let name = (m["name"] as? String ?? "") + ".bin"
            if let d = try? Data(contentsOf: Bridge.docs.appendingPathComponent(name)) {
                return ["b64": d.base64EncodedString()]
            }
            return ["b64": NSNull()]
        default: return ["error": "unknown \(kind)"]
        }
    }
 
    private func httpRequest(_ m: [String: Any]) -> [String: Any] {
        guard let urlStr = m["url"] as? String, let url = URL(string: urlStr) else {
            return ["error": "bad url"]
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = m["method"] as? String ?? "GET"
        if let h = m["headers"] as? [String: String] { for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) } }
        if let b64 = m["bodyB64"] as? String, let d = Data(base64Encoded: b64) { req.httpBody = d }
        else if let b = m["body"] as? String { req.httpBody = b.data(using: .utf8) }
 
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = ["error": "no response"]
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { out = ["error": "\(err.localizedDescription)"]; sem.signal(); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (m["binary"] as? Bool) == true {
                out = ["status": status, "b64": (data ?? Data()).base64EncodedString()]
            } else {
                out = ["status": status, "text": String(data: data ?? Data(), encoding: .utf8) ?? ""]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 65)
        return out
    }
 
    // ---- actions that touch UIKit ----
    private var pickReply: ((Any?, String?) -> Void)?
    private var pickMode = "pick"
 
    private func handleUI(_ kind: String, _ m: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
        DispatchQueue.main.async {
            switch kind {
            case "open":
                if let s = m["url"] as? String, let u = URL(string: s) { UIApplication.shared.open(u) }
                reply(["ok": true], nil)
            case "saveFile":
                let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "project.dlj"
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                if let b64 = m["b64"] as? String, let d = Data(base64Encoded: b64) {
                    try? d.write(to: tmp)
                    let av = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
                    self.present(av)
                }
                reply(["ok": true], nil)
            case "pick":
                self.pickReply = reply
                let types = UTType("public.item").map { [$0] } ?? [.data]
                let p = UIDocumentPickerViewController(forOpeningContentTypes: types)
                p.delegate = self
                self.present(p)
            default:
                reply(["error": "unknown"], nil)
            }
        }
    }
 
    private func present(_ vc: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
 
    private func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
 
extension Bridge: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let reply = pickReply, let url = urls.first else { pickReply?(["error": "cancelled"], nil); pickReply = nil; return }
        pickReply = nil
        let needStop = url.startAccessingSecurityScopedResource()
        defer { if needStop { url.stopAccessingSecurityScopedResource() } }
        if let d = try? Data(contentsOf: url) {
            reply(["name": url.lastPathComponent, "b64": d.base64EncodedString()], nil)
        } else {
            reply(["error": "read failed"], nil)
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickReply?(["error": "cancelled"], nil); pickReply = nil
    }
}
 
extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } ?? windows.first }
}
 
