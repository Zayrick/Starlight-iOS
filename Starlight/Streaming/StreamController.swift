//
//  StreamController.swift
//  Starlight
//
//  Owns the active stream. moonlight-common-c supports one connection at a
//  time, so there's at most one session.
//

import Foundation
import Observation

@Observable
final class StreamController {
    private(set) var session: StreamSession?

    /// Starts streaming `app`, unless a stream is already active.
    func start(host: StreamHost, app: StreamApp, quitsRunningApp: Bool = false) {
        guard session == nil else { return }
        let session = StreamSession(host: host, app: app, quitsRunningApp: quitsRunningApp)
        self.session = session
        session.start()
    }

    /// Ends the active stream and dismisses it.
    func close(quitApp: Bool = false) {
        session?.stop(quitApp: quitApp)
        session = nil
    }
}
