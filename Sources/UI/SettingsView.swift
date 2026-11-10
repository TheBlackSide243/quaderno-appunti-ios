import SwiftUI
import UniformTypeIdentifiers

/// Backup to iCloud Drive and a few facts about the app.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(CloudBackup.self) private var backup
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var confirmRestore = false

    var body: some View {
        @Bindable var backup = backup
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Panel("iCloud Drive") {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "icloud.fill").font(.title2).foregroundStyle(Theme.accent)
                            Text("Scegli una cartella in iCloud Drive (per esempio una nuova cartella «Appunti»): l'app ci copia i quaderni e iCloud li carica. Da un altro iPhone o iPad scegli la stessa cartella e tocca Ripristina.")
                                .font(.footnote).foregroundStyle(Theme.sub)
                        }
                        if backup.configured {
                            InfoRow("Cartella", backup.folderName ?? "")
                            InfoRow("Ultimo salvataggio", backup.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? "mai")
                            Toggle("Salva automaticamente", isOn: $backup.auto)
                                .tint(Theme.accent)
                                .font(.subheadline)
                            Text("Dopo aver chiuso un quaderno e quando l'app va in secondo piano.")
                                .font(.caption).foregroundStyle(Theme.sub)
                            HStack(spacing: 10) {
                                Button {
                                    backup.backupNow(library)
                                } label: {
                                    Label(backup.running ? "Salvataggio…" : "Salva adesso", systemImage: "icloud.and.arrow.up")
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(backup.running)
                                Button { confirmRestore = true } label: {
                                    Label("Ripristina", systemImage: "icloud.and.arrow.down")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(backup.running)
                            }
                            if backup.running { ProgressView().frame(maxWidth: .infinity) }
                            if let m = backup.message {
                                Label(m, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.good)
                            }
                            HStack {
                                Button("Cambia cartella") { picking = true }
                                Spacer()
                                Button("Scollega", role: .destructive) { backup.forget() }
                            }
                            .font(.footnote.weight(.semibold))
                        } else {
                            Button { picking = true } label: {
                                Label("Scegli cartella in iCloud Drive", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        ErrorBanner(error: $backup.error)
                    }
                    Panel("Sul dispositivo") {
                        InfoRow("Quaderni", "\(library.notebooks.count)")
                        InfoRow("Cartelle", "\(library.folders.count)")
                        Text("I quaderni si trovano anche in File → Sul mio iPhone (o iPad) → Appunti → Quaderni.")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                    Panel("Informazioni") {
                        InfoRow("Versione", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                        Text("La scrittura a mano viene riconosciuta sul dispositivo: nessun appunto lascia il telefono, salvo nella cartella iCloud Drive che scegli tu.")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .screen()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                backup.choose(url)
                if backup.configured, !library.notebooks.isEmpty { backup.backupNow(library) }
            }
        }
        .confirmationDialog("Ripristinare da «\(backup.folderName ?? "")»? I quaderni che mancano qui vengono aggiunti e quelli più recenti nella cartella sostituiscono quelli di questo dispositivo.",
                            isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Ripristina") { backup.restore(library) }
        }
        .preferredColorScheme(.dark)
    }
}
