# Quaderno Appunti

App per iPhone e iPad (SwiftUI, iOS 17+) per prendere appunti a mano, nello stile dei quaderni
digitali: Apple Pencil o dito, quaderni con copertina, PDF da annotare e ricerca nella scrittura.

## Schermate

**iPhone**

<p>
  <img src="docs/screenshots/iphone-library.jpg" width="200" alt="Libreria su iPhone">
  <img src="docs/screenshots/iphone-editor.jpg" width="200" alt="Quaderno a righe con la barra strumenti">
  <img src="docs/screenshots/iphone-shapes.jpg" width="200" alt="Strumento Forme">
  <img src="docs/screenshots/iphone-new.jpg" width="200" alt="Nuovo quaderno">
  <img src="docs/screenshots/iphone-search.jpg" width="200" alt="Ricerca negli appunti">
  <img src="docs/screenshots/iphone-intro.jpg" width="200" alt="Introduzione al primo avvio">
</p>

**iPad**

| | |
|---|---|
| <img src="docs/screenshots/ipad-library.jpg" alt="Libreria su iPad"> | <img src="docs/screenshots/ipad-editor.jpg" alt="Appunti di fisica"> |
| Libreria: cartelle, copertine, prima pagina come copertina | Scrittura, evidenziatore, testo e disegni |
| <img src="docs/screenshots/ipad-pdf.jpg" alt="PDF annotato"> | <img src="docs/screenshots/ipad-math.jpg" alt="Grafico su carta a quadretti"> |
| PDF evidenziato e annotato | Carta a quadretti, grafico e area sotto la curva |
| <img src="docs/screenshots/ipad-shapes.jpg" alt="Forme: rettangoli, ellissi, frecce e linee"> | <img src="docs/screenshots/ipad-ocr.jpg" alt="Testo riconosciuto di una pagina"> |
| Forme: rettangoli, ellissi, frecce e linee | Testo riconosciuto della pagina, da copiare |
| <img src="docs/screenshots/ipad-new.jpg" alt="Nuovo quaderno su iPad"> | <img src="docs/screenshots/ipad-settings.jpg" alt="Impostazioni e iCloud Drive"> |
| Nuovo quaderno: copertina, carta e modelli | Impostazioni: salvataggio su iCloud Drive |

<sub>Schermate dal simulatore iOS con quaderni d'esempio (la scrittura a mano è finta).</sub>

## Cosa fa

- **Libreria** a griglia o a elenco, ordinata per data, nome o tipo; cartelle, preferiti e un
  menu sotto ogni quaderno (rinomina, copertina, sposta, duplica, esporta, elimina).
  I quaderni eliminati restano 30 giorni nel **cestino** (Impostazioni → Cestino).
- **Copertine** semplici, con elastico o con etichetta, in 13 colori, oppure la prima pagina.
- **Pagine** bianche, a puntini, a quadretti, a righe, a righe strette, Cornell, elenco con
  caselle o pentagramma; carta bianca, avorio, gialla o grigia; A4 verticale/orizzontale,
  Lettera o quadrato. Griglia delle pagine per saltare, duplicare, spostare o eliminare;
  **segnalibri** per ritrovare subito le pagine importanti.
- **Barra strumenti** sempre in vista: penna, matita, evidenziatore, gomma (tratto intero,
  piccola, grande), **forme** (linea, freccia, rettangolo, ellisse), lazo, mano per spostare
  testi e foto, righello; tre spessori e tre colori per strumento più un colore a scelta,
  ricordati tra un quaderno e l'altro. Zoom a due dita, annulla/ripeti. Si cambia pagina anche
  tirando oltre la fine del foglio. Su iPad si può scrivere solo con la Pencil e scorrere col
  dito; il doppio tocco sulla Pencil passa alla gomma e torna indietro.
- **PDF**: importa un PDF come nuovo quaderno (anche con "Apri con" dall'app File) o aggiungine
  le pagine a un quaderno esistente, e scrivici sopra. Un quaderno si crea anche da foto o
  **scansionando un documento** con la fotocamera.
- **Testo e foto** sulla pagina: riquadri di testo (dimensione, grassetto, colore) e immagini,
  da trascinare e ridimensionare; **Incolla** mette sulla pagina il testo o l'immagine copiati.
- **Ricerca** nei titoli, nella scrittura a mano (riconosciuta sul dispositivo con Vision, in
  italiano e inglese), nei riquadri di testo e nel testo dei PDF, in tutta la libreria o solo
  nel quaderno aperto. **Testo riconosciuto** mostra il testo di una pagina, da copiare.
- **Esporta** il quaderno o una pagina in PDF, o la pagina come immagine, da condividere,
  stampare o salvare in File.
- **Introduzione** in cinque schede al primo avvio, da rivedere quando si vuole dalle
  Impostazioni o dal "?" della libreria.

## iCloud Drive

In *Impostazioni → iCloud Drive* si sceglie una cartella (per esempio una nuova cartella
«Quaderno Appunti» in iCloud Drive): l'app ci copia i quaderni dopo averne chiuso uno e quando va in
secondo piano, oppure con *Salva adesso*. Su un altro iPhone o iPad si sceglie la stessa
cartella e si tocca *Ripristina*.

La sincronizzazione iCloud automatica di Apple richiede un account sviluppatore a pagamento e
non funziona con le app installate con Feather o Sideloadly; una cartella scelta in File invece
funziona sempre. I quaderni restano comunque anche sul dispositivo, in
*File → Sul mio iPhone → Quaderno Appunti → Quaderni*.

## Compilare

Nessun Mac necessario: `.github/workflows/ipa.yml` genera il progetto con XcodeGen e produce
`Quaderno-Appunti-<versione>-unsigned.ipa` (artefatto `appunti-ipa`), da installare con Feather,
Sideloadly o AltStore. Nuova versione: aumentare `MARKETING_VERSION` in `project.yml`.

`.github/workflows/testflight.yml` carica la stessa versione su TestFlight (identificativo
`win.shadowbyte.appunti`) a ogni release `v…`, firmandola con la chiave API di App Store Connect
salvata nei secret del repository.

Le schermate qui sopra le fa `.github/workflows/screenshots.yml` (avvio manuale): compila per il
simulatore e lancia `scripts/screenshots.sh`, che apre l'app con `-demo -screen <nome>` su un
iPhone e un iPad con dei quaderni d'esempio.
