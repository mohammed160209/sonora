import Foundation
import Observation

/// The public Sonora Sessions v1 wire format. Only catalog metadata crosses the socket.
private struct SessionTrack: Codable {
    struct Duration: Codable { let secs: UInt64; let nanos: UInt32 }
    struct Artist: Codable { let name: String; let id: String? }

    let id: String?
    let name: String
    let playable: Bool
    let artists: String
    let artist_refs: [Artist]?
    let album: String?
    let album_id: String?
    let cover: URL?
    let duration: Duration?
    let explicit: Bool?

    init?(_ track: MusicTrack) {
        guard let id = track.youtubeID, track.available != false else { return nil }
        self.id = id
        name = track.title
        playable = true
        artists = track.artist
        artist_refs = [Artist(name: track.artist, id: track.artistID)]
        album = track.albumTitle ?? ""
        album_id = track.albumID
        cover = track.artworkURL.flatMap { $0.scheme == "https" ? $0 : nil }
        let seconds = track.durationSeconds ?? 0
        duration = Duration(secs: UInt64(seconds.isFinite ? min(max(0, seconds), 604_800) : 0), nanos: 0)
        explicit = track.explicit
    }

    var track: MusicTrack? {
        guard playable, let id, id.utf8.count == 11,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let seconds = duration.map { Double($0.secs) + Double($0.nanos) / 1_000_000_000 }
        return MusicTrack(id: "youtube:" + id, title: name, artist: artists, filename: "", addedAt: .now,
            youtubeID: id, artistID: artist_refs?.first?.id, albumTitle: album, albumID: album_id,
            artworkURL: cover.flatMap { $0.scheme == "https" ? $0 : nil },
            durationSeconds: seconds.flatMap { $0 > 0 && $0 <= 604_800 ? $0 : nil }, explicit: explicit ?? false, available: true)
    }
}

private struct SharedListeningState: Codable {
    let track: SessionTrack?
    let upcoming: [SessionTrack]?
    let playing: Bool
    let position: UInt64
    let at: UInt64?
}

private struct SessionReply: Decodable {
    let type: String
    let code: String?
    let provider: String?
    let you: String?
    let members: [ListeningSession.Member]?
    let state: SharedListeningState?
    let by: String?
    let seq: UInt64?
    let t: UInt64?
    let now: UInt64?
    let reason: String?
}

/// Owns the socket for the lifetime of the app, independent of whether the Sessions sheet is open.
@MainActor @Observable
final class ListeningSession {
    struct Member: Decodable, Identifiable {
        let id: String
        let name: String
        let host: Bool
    }

    private struct PlaybackMark: Equatable {
        let track: String?
        let upcoming: [String]
        let playing: Bool
        let seek: Int
    }

    static let official = URL(string: "wss://sessions.sonorahq.org/ws")!
    private static let provider = "youtube"
    private static let queueLimit = 100

    private(set) var code: String?
    private(set) var members: [Member] = []
    private(set) var busy = false
    private(set) var server = UserDefaults.standard.url(forKey: "sonora.listening.server") ?? ListeningSession.official
    private(set) var message: String?
    private var ownID: String?
    var hosting: Bool { members.contains { $0.id == ownID && $0.host } }
    func isSelf(_ member: Member) -> Bool { member.id == ownID }

    @ObservationIgnored private lazy var network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private weak var playback: PlaybackController?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var baseline: PlaybackMark?
    @ObservationIgnored private var shared: SharedListeningState?
    @ObservationIgnored private var sent: UInt64 = 0
    @ObservationIgnored private var echoed: UInt64 = 0
    @ObservationIgnored private var samples: [(roundTrip: Int64, offset: Int64)] = []
    @ObservationIgnored private var lastPong: Int64 = 0
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var listenerName = ""

    func start(name: String, playback: PlaybackController) { begin(code: nil, name: name, playback: playback) }

    func join(code: String, name: String, playback: PlaybackController) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            message = String(localized: "ios-session-code-invalid")
            return
        }
        begin(code: code, name: name, playback: playback)
    }

    private func begin(code: String?, name: String, playback: PlaybackController) {
        guard self.code == nil, !busy else { return }
        guard !NetworkAccess.shared.isOffline else {
            message = String(localized: "ios-offline-required")
            return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { message = String(localized: "ios-session-name-required"); return }
        listenerName = String(name.prefix(40))
        self.playback = playback
        message = nil
        connect(code: code)
    }

    /// Custom servers use the same protocol and must pass the upstream health check over HTTPS.
    func saveServer(_ address: String) async {
        guard code == nil, !busy else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = address.contains("://") ? address : "wss://" + address
        guard var parts = URLComponents(string: normalized), parts.host != nil,
              ["wss", "https"].contains(parts.scheme ?? ""), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            message = String(localized: "ios-session-server-invalid")
            return
        }
        parts.scheme = "wss"
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/ws" }
        guard let socketURL = parts.url else { return }
        parts.scheme = "https"
        parts.path = "/health"
        guard let health = parts.url else { return }
        busy = true
        defer { busy = false }
        do {
            let (data, response) = try await NetworkAccess.shared.data(for: URLRequest(url: health, timeoutInterval: 6))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            else { throw URLError(.badServerResponse) }
            server = socketURL
            UserDefaults.standard.set(socketURL, forKey: "sonora.listening.server")
            message = String(localized: "ios-session-server-saved")
        } catch { message = String(localized: "ios-session-unreachable") }
    }

    func leave() {
        if let socket {
            // Write the explicit leave before closing. The server also handles disconnects.
            let previous = sendTask
            Task {
                await previous?.value
                try? await socket.send(.string("{\"type\":\"leave\"}"))
                socket.cancel(with: .normalClosure, reason: nil)
            }
        }
        reset(close: false)
        message = nil
    }

    func kick(_ member: Member) {
        guard hosting, !isSelf(member) else { return }
        send(["type": "kick", "member": member.id])
    }

    private func connect(code: String?) {
        retryTask?.cancel()
        retryTask = nil
        guard !NetworkAccess.shared.isOffline else { reset(); return }
        busy = true
        sent = 0; echoed = 0; baseline = nil; shared = nil; samples.removeAll()
        lastPong = Self.now
        let socket = network.webSocketTask(with: server)
        socket.maximumMessageSize = 512 * 1024
        self.socket = socket
        socket.resume()
        var first: [String: Any] = ["version": 1, "name": listenerName]
        if let code {
            first["type"] = "join"; first["code"] = code; first["providers"] = [Self.provider]
        } else {
            first["type"] = "create"; first["provider"] = Self.provider
        }
        send(first)
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    guard let self, self.socket === socket else { return }
                    guard case .string(let text) = frame,
                          let reply = try? JSONDecoder().decode(SessionReply.self, from: Data(text.utf8)) else { continue }
                    self.receive(reply)
                }
            } catch { self?.lost(socket) }
        }
        pulseTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, self.socket === socket else { return }
                if Self.now - self.lastPong > 15_000 { self.lost(socket); return }
                if tick.isMultiple(of: 10) { self.send(["type": "ping", "t": Self.now]) }
                self.publish()
                if tick.isMultiple(of: 4) { self.correctDrift() }
                tick += 1
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func receive(_ reply: SessionReply) {
        switch reply.type {
        case "joined":
            guard let code = reply.code, let ownID = reply.you, reply.provider == Self.provider else {
                fail(String(localized: "ios-session-provider")); return
            }
            self.code = code; self.ownID = ownID; members = reply.members ?? []
            busy = false; retries = 0; message = nil
            if let state = reply.state { apply(state) } else { publish() }
        case "members": members = reply.members ?? []
        case "state":
            guard let state = reply.state else { return }
            if reply.by == ownID {
                let seq = reply.seq ?? 0
                echoed = max(echoed, seq)
                if seq == sent { shared = state }
            } else if echoed == sent { apply(state) }
        case "pong":
            guard let t = reply.t, let now = reply.now, t <= UInt64(Int64.max), now <= UInt64(Int64.max) else { return }
            let here = Self.now
            let trip = here - Int64(t)
            guard (0...15_000).contains(trip) else { return }
            let serverClock = Int64(now)
            guard abs(serverClock - here) < 86_400_000 else { return }
            lastPong = here
            samples.append((trip, serverClock - here + trip / 2))
            if samples.count > 8 { samples.removeFirst() }
        case "ended": fail(String(localized: "ios-session-ended"))
        case "kicked": fail(String(localized: "ios-session-kicked"))
        case "error":
            let reason: String
            switch reply.reason {
            case "not_found": reason = String(localized: "ios-session-not-found")
            case "provider": reason = String(localized: "ios-session-provider")
            case "full": reason = String(localized: "ios-session-full")
            case "rate_limited", "too_many": reason = String(localized: "ios-session-limit")
            default: reason = String(localized: "ios-session-failed")
            }
            if busy { fail(reason) }
            else { echoed = sent; message = reason }
        default: break
        }
    }

    private func mark(_ playback: PlaybackController) -> PlaybackMark {
        PlaybackMark(track: playback.current?.youtubeID,
            upcoming: Array(playback.upcomingItems.lazy.compactMap { $0.track.youtubeID }.prefix(Self.queueLimit)),
            playing: playback.sessionWantsPlayback, seek: playback.sessionSeekRevision)
    }

    private func publish() {
        guard code != nil, !busy, let playback else { return }
        let next = mark(playback)
        guard next != baseline else { return }
        let track = playback.current.flatMap(SessionTrack.init)
        let upcoming = Array(playback.upcomingItems.lazy.compactMap { SessionTrack($0.track) }.prefix(Self.queueLimit))
        let seconds = playback.sessionPosition
        let position = UInt64((seconds.isFinite ? min(max(0, seconds), 604_800) : 0) * 1_000)
        let state = SharedListeningState(track: track, upcoming: upcoming,
            playing: track != nil && next.playing, position: position, at: 0)
        guard let encoded = try? JSONEncoder().encode(state),
              let payload = try? JSONSerialization.jsonObject(with: encoded) else { return }
        sent += 1
        baseline = next
        send(["type": "state", "state": payload, "seq": sent])
    }

    private func apply(_ state: SharedListeningState) {
        guard let playback else { return }
        shared = state
        playback.applySession(track: state.track?.track,
            upcoming: Array((state.upcoming ?? []).prefix(Self.queueLimit)).compactMap(\.track),
            playing: state.playing, position: position(state))
        baseline = mark(playback)
    }

    private func correctDrift() {
        guard !busy, echoed == sent, let state = shared, let track = state.track?.track,
              let playback, !playback.isLoading, playback.current?.id == track.id,
              playback.sessionWantsPlayback == state.playing,
              abs(playback.sessionPosition - position(state)) > 2.5 else { return }
        playback.seek(to: position(state), publishToSession: false)
    }

    private func position(_ state: SharedListeningState) -> Double {
        let offset = samples.min(by: { $0.roundTrip < $1.roundTrip })?.offset ?? 0
        let now = UInt64(max(0, Self.now + offset))
        let at = state.at ?? 0
        let advance = state.playing && at > 0 && now > at ? now - at : 0
        let seconds = (Double(state.position) + Double(advance)) / 1_000
        return min(seconds, state.track?.track?.durationSeconds ?? 604_800)
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private func send(_ value: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        let previous = sendTask
        sendTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.socket === socket else { return }
            do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
            catch { self.lost(socket) }
        }
    }

    private func lost(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        disconnect()
        guard let code, retries < 8, !NetworkAccess.shared.isOffline else {
            fail(String(localized: "ios-session-unreachable"))
            return
        }
        busy = true
        let delay = 1 << min(retries, 4)
        retries += 1
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.connect(code: code)
        }
    }

    private func disconnect(close: Bool = true) {
        if close { socket?.cancel(with: .goingAway, reason: nil) }
        socket = nil
        receiveTask?.cancel(); receiveTask = nil
        pulseTask?.cancel(); pulseTask = nil
        sendTask?.cancel(); sendTask = nil
    }

    private func reset(close: Bool = true) {
        disconnect(close: close)
        retryTask?.cancel(); retryTask = nil
        code = nil; members = []; ownID = nil; busy = false
        baseline = nil; shared = nil; retries = 0
    }

    private func fail(_ reason: String) { reset(); message = reason }
}
