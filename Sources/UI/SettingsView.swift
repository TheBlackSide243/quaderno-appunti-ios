import SwiftUI
import UniformTypeIdentifiers

/// Backup to iCloud Drive and a few facts about the app.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(CloudBackup.self) private var backup
    @Environment(\.dismiss) private var dismiss
    var onIntro: (() -> Void)?
    @State private var picking = false
    @State private var spotlight = Spotlight.enabled

    var body: some View {
        @Bindable var backup = backup
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Panel("Sincronizzazione con iCloud Drive") {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath.icloud.fill").font(.title2).foregroundStyle(Theme.accent)
                            Text("Scegli una cartella in iCloud Drive (per esempio una nuova cartella «Quaderno Appunti») e la stessa cartella sugli altri iPhone e iPad: i quaderni restano uguali su tutti. Le modifiche più recenti vincono, i quaderni eliminati spariscono anche dagli altri.")
                                .font(.footnote).foregroundStyle(Theme.sub)
                        }
                        if backup.configured {
                            InfoRow("Cartella", backup.folderName ?? "")
                            InfoRow("Ultima sincronizzazione", backup.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "mai"))
                            Toggle("Sincronizza automaticamente", isOn: $backup.auto)
                                .tint(Theme.accent)
                                .font(.subheadline)
                            Text("Quando apri l'app, dopo aver chiuso un quaderno e quando l'app va in secondo piano.")
                                .font(.caption).foregroundStyle(Theme.sub)
                            Button {
                                backup.syncNow(library)
                            } label: {
                                Label(backup.running ? String(localized: "Sincronizzazione…") : String(localized: "Sincronizza adesso"), systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(backup.running)
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
                    Panel("Ricerca dell'iPhone") {
                        Toggle("Mostra i quaderni in Spotlight", isOn: $spotlight)
                            .tint(Theme.accent)
                            .font(.subheadline)
                            .onChange(of: spotlight) { _, on in
                                Spotlight.enabled = on
                                if on { Spotlight.shared.reindexAll(library.notebooks) } else { Spotlight.shared.removeAll() }
                            }
                        Text("Scorri giù nella schermata Home e scrivi una parola: trovi i quaderni e le pagine dove l'hai scritta, anche a mano. Tutto resta sul dispositivo.")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                    Panel("Sul dispositivo") {
                        InfoRow("Quaderni", "\(library.notebooks.count)")
                        InfoRow("Cartelle", "\(library.folders.count)")
                        NavigationLink {
                            TrashView()
                        } label: {
                            HStack {
                                Label("Cestino", systemImage: "trash")
                                Spacer()
                                Text("\(library.trashed.count)").foregroundStyle(Theme.sub)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.sub)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        Text("I quaderni si trovano anche in File → Sul mio iPhone (o iPad) → Quaderno Appunti → Quaderni.")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                    Panel("Informazioni") {
                        if let onIntro {
                            Button(action: onIntro) {
                                Label("Guarda l'introduzione", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
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
                if backup.configured { backup.syncNow(library) }
            }
        }
        .preferredColorScheme(.dark)
    }
}
