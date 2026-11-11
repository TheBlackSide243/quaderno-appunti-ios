import AVFoundation
import Observation
import SwiftUI

/// Records sound while writing and plays it back. The recordings belong to the notebook
/// (audio/<id>.m4a in its folder); every stroke knows when it was written, so a tap on the
/// writing jumps to that moment of the recording.
@MainActor
@Observable
final class AudioNotes: NSObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    let notebookID: UUID
    /// The audio bar is open.
    var panel = false
    private(set) var recording = false
    private(set) var elapsed: Double = 0
    /// The recording loaded in the player.
    private(set) var current: Recording?
    private(set) var playing = false
    private(set) var position: Double = 0
    var error: String?
    /// A tap on the writing plays what was said while it was written.
    var listening = false {
        didSet { if listening != oldValue { onListenChange?(listening) } }
    }

    @ObservationIgnored var onSaved: ((Recording) -> Void)?
    @ObservationIgnored var onListenChange: ((Bool) -> Void)?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started: Recording?

    init(notebookID: UUID) {
        self.notebookID = notebookID
        super.init()
    }

    // MARK: Recording

    func startRecording() {
        guard !recording else { return }
        stopPlaying()
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.error = String(localized: "Per registrare consenti il microfono: Impostazioni → Quaderno Appunti → Microfono.")
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: Store.audioDir(notebookID), withIntermediateDirectories: true)
            let rec = Recording(start: Date(), duration: 0)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 32_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: Store.audio(notebookID, rec.id), settings: settings)
            r.delegate = self
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
            started = Recording(id: rec.id, start: Date(), duration: 0)
            recording = true
            elapsed = 0
            error = nil
            startTimer()
        } catch {
            self.error = String(localized: "Non riesco a registrare: \(error.localizedDescription)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stopRecording() {
        guard recording, let r = recorder, var rec = started else { return }
        rec.duration = r.currentTime
        r.stop()
        recorder = nil
        started = nil
        recording = false
        stopTimerIfIdle()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if rec.duration >= 1 {
            onSaved?(rec)
            load(rec)
        } else {
            try? FileManager.default.removeItem(at: Store.audio(notebookID, rec.id))
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.stopRecording() }
    }

    // MARK: Playing

    /// Loads a recording without playing it.
    func load(_ rec: Recording) {
        guard current?.id != rec.id || player == nil else { return }
        stopPlaying()
        do {
            let p = try AVAudioPlayer(contentsOf: Store.audio(notebookID, rec.id))
            p.delegate = self
            p.prepareToPlay()
            player = p
            current = rec
            position = 0
        } catch {
            self.error = String(localized: "Questa registrazione non si apre: forse non è ancora stata scaricata.")
        }
    }

    func play(_ rec: Recording, at time: Double) {
        guard !recording else { return }
        panel = true
        load(rec)
        guard let p = player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.currentTime = min(max(0, time), max(0, p.duration - 0.1))
        p.play()
        playing = true
        position = p.currentTime
        startTimer()
    }

    func togglePlay() {
        guard let rec = current else { return }
        if playing {
            player?.pause()
            playing = false
            stopTimerIfIdle()
        } else {
            play(rec, at: position >= duration - 0.2 ? 0 : position)
        }
    }

    func seek(_ t: Double) {
        position = t
        player?.currentTime = t
    }

    func skip(_ delta: Double) { seek(min(max(0, position + delta), duration)) }

    var duration: Double { player?.duration ?? current?.duration ?? 0 }

    private func stopPlaying() {
        player?.stop()
        playing = false
        stopTimerIfIdle()
    }

    /// The recording was deleted.
    func forget(_ rec: Recording) {
        if current?.id == rec.id {
            stopPlaying()
            player = nil
            current = nil
            position = 0
        }
    }

    /// Closing the notebook: what is being recorded is saved.
    func stopAll() {
        stopRecording()
        stopPlaying()
        listening = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            self.position = self.duration
            self.stopTimerIfIdle()
        }
    }

    // MARK: Clock

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if recording, let r = recorder { elapsed = r.currentTime }
        if playing, let p = player { position = p.currentTime }
    }

    private func stopTimerIfIdle() {
        guard !recording, !playing else { return }
        timer?.invalidate()
        timer = nil
    }

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The bar at the bottom of the page for recording and listening.
struct AudioBar: View {
    let model: EditorModel
    var onShare: (URL) -> Void

    private var audio: AudioNotes { model.audio }

    var body: some View {
        VStack(spacing: 8) {
            if audio.recording {
                recordingRow
            } else {
                playerRow
            }
            if let e = audio.error {
                Text(e).font(.caption).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
                    .onTapGesture { audio.error = nil }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .frame(maxWidth: 620)
    }

    private var recordingRow: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.bad).frame(width: 10, height: 10)
            Text("Registrazione").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            Text(AudioNotes.clock(audio.elapsed)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.sub)
            Spacer()
            Button { audio.stopRecording() } label: {
                Label("Ferma", systemImage: "stop.fill").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.bad)
        }
    }

    private var playerRow: some View {
        HStack(spacing: 10) {
            Button { audio.startRecording() } label: {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(Theme.bad)
            }
            .accessibilityLabel("Registra")
            if audio.current != nil {
                Button { audio.skip(-10) } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel("Indietro di 10 secondi")
                Button { audio.togglePlay() } label: {
                    Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 28)
                }
                .accessibilityLabel(audio.playing ? String(localized: "Pausa") : String(localized: "Riproduci"))
                Slider(value: Binding(get: { audio.position }, set: { audio.seek($0) }), in: 0...max(1, audio.duration))
                    .tint(Theme.accent)
                Text("\(AudioNotes.clock(audio.position)) / \(AudioNotes.clock(audio.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.sub)
                    .fixedSize()
            } else {
                Text(model.recordings.isEmpty ? String(localized: "Tocca il pallino rosso per registrare mentre scrivi.") : String(localized: "Scegli una registrazione dall'elenco."))
                    .font(.caption).foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.recordings.isEmpty {
                Button { audio.listening.toggle() } label: {
                    Image(systemName: "hand.tap").font(.body.weight(audio.listening ? .bold : .regular))
                        .foregroundStyle(audio.listening ? Theme.bg : Theme.text)
                        .frame(width: 34, height: 30)
                        .background(audio.listening ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Tocca la scrittura per ascoltare")
                Menu { recordingsMenu } label: { Image(systemName: "list.bullet").frame(width: 30, height: 30) }
                    .accessibilityLabel("Registrazioni")
            }
            Button { audio.stopAll(); audio.panel = false } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.sub).frame(width: 26, height: 30)
            }
            .accessibilityLabel("Chiudi")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private var recordingsMenu: some View {
        Section("Registrazioni") {
            ForEach(model.recordings.reversed()) { rec in
                Button { audio.play(rec, at: 0) } label: {
                    let name = rec.start.formatted(.dateTime.day().month(.abbreviated).hour().minute()) + " · " + AudioNotes.clock(rec.duration)
                    if audio.current?.id == rec.id { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        }
        if let rec = audio.current {
            Section {
                Button { onShare(Store.audio(model.notebook.id, rec.id)) } label: {
                    Label("Condividi questa registrazione", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { model.deleteRecording(rec) } label: {
                    Label("Elimina questa registrazione", systemImage: "trash")
                }
            }
        }
    }
}
