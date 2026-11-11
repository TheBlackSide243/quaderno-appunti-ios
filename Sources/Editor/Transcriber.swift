import AVFoundation
import Speech
import SwiftUI

/// Turns a recording into text with Apple's speech recognition, on the device when the language
/// allows it. The audio is read in pieces of 50 seconds, so long recordings work too.
enum Transcriber {
    enum Failure: LocalizedError {
        case denied, unavailable, nothing

        var errorDescription: String? {
            switch self {
            case .denied:
                String(localized: "Per trascrivere consenti il riconoscimento vocale: Impostazioni → Quaderno Appunti → Riconoscimento vocale.")
            case .unavailable:
                String(localized: "Il riconoscimento vocale per questa lingua adesso non è disponibile. Riprova con la connessione a internet.")
            case .nothing:
                String(localized: "In questa registrazione non ho sentito parole.")
            }
        }
    }

    static var defaultLanguage: String {
        Locale.current.language.languageCode?.identifier == "en" ? "en-US" : "it-IT"
    }

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// The text of the recording. `progress` goes from 0 to 1.
    static func transcribe(_ url: URL, language: String, progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        guard await authorize() else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw Failure.unavailable
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = file.length
        let piece = AVAudioFramePosition(format.sampleRate * 50)
        var parts: [String] = []
        var pos: AVAudioFramePosition = 0
        while pos < total {
            try Task.checkCancellation()
            let end = min(total, pos + piece)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            file.framePosition = pos
            while file.framePosition < end {
                let n = AVAudioFrameCount(min(8192, end - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
                try file.read(into: buffer, frameCount: n)
                if buffer.frameLength == 0 { break }
                request.append(buffer)
            }
            request.endAudio()
            let text = try await recognize(request, with: recognizer)
            if !text.isEmpty { parts.append(text) }
            pos = end
            await progress(Double(pos) / Double(max(1, total)))
        }
        let all = parts.joined(separator: " ")
        if all.isEmpty { throw Failure.nothing }
        return all
    }

    private final class Running: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
        var done = false
    }

    private static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer) async throws -> String {
        let run = Running()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                run.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !run.done else { return }
                    if let result, result.isFinal {
                        run.done = true
                        c.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        run.done = true
                        // "no speech detected": a silent piece, not a failure of the whole recording
                        let ns = error as NSError
                        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 {
                            c.resume(returning: "")
                        } else {
                            c.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            run.task?.cancel()
        }
    }
}

/// The text of a recording: to read, copy, share or put on the page as a text box.
struct TranscriptView: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel
    let recording: Recording
    @State private var text = ""
    @State private var language = Transcriber.defaultLanguage
    @State private var working = false
    @State private var progress = 0.0
    @State private var error: String?
    @State private var copied = false
    @State private var job: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(recording.start.formatted(.dateTime.day().month(.wide).hour().minute()) + " · " + AudioNotes.clock(recording.duration))
                        .font(.subheadline).foregroundStyle(Theme.sub)
                    Picker("Lingua", selection: $language) {
                        Text("Italiano").tag("it-IT")
                        Text("Inglese").tag("en-US")
                    }
                    .pickerStyle(.segmented)
                    .disabled(working)
                    if working {
                        VStack(spacing: 12) {
                            ProgressView(value: progress).tint(Theme.accent)
                            Text("Trascrivo la registrazione…").font(.subheadline).foregroundStyle(Theme.sub)
                        }
                        .padding(.vertical, 30)
                    } else if let error {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.badge.exclamationmark").font(.system(size: 34)).foregroundStyle(Theme.accent)
                            Text(error).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                            Button("Riprova") { start() }.buttonStyle(.bordered).tint(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else if !text.isEmpty {
                        Panel(String(localized: "Testo")) {
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            model.insertText(text)
                            dismiss()
                        } label: {
                            Label("Inserisci nella pagina", systemImage: "text.badge.plus")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.bg)
                        Text("Il testo resta salvato con la registrazione e si trova anche con la ricerca.")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Trascrizione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !text.isEmpty && !working {
                        ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel("Copia tutto")
                    }
                }
            }
            .screen()
        }
        .onAppear {
            if let saved = recording.transcript, !saved.isEmpty { text = saved } else { start() }
        }
        .onChange(of: language) { _, _ in start() }
        .onDisappear { job?.cancel() }
        .preferredColorScheme(.dark)
    }

    private func start() {
        job?.cancel()
        working = true
        error = nil
        progress = 0
        copied = false
        let url = Store.audio(model.notebook.id, recording.id)
        let lang = language
        job = Task {
            do {
                let result = try await Transcriber.transcribe(url, language: lang) { progress = $0 }
                if Task.isCancelled { return }
                text = result
                model.setTranscript(recording, result)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
