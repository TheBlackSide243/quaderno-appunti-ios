# Appunti

App per iPhone e iPad (SwiftUI, iOS 17+) per prendere appunti a mano, nello stile dei quaderni
digitali: Apple Pencil o dito, quaderni con copertina, PDF da annotare e ricerca nella scrittura.

<!-- SCREENSHOTS -->

## Cosa fa

- **Libreria** a griglia o a elenco, ordinata per data, nome o tipo; cartelle, preferiti e un
  menu sotto ogni quaderno (rinomina, copertina, sposta, duplica, esporta, elimina).
- **Copertine** semplici, con elastico o con etichetta, in 13 colori, oppure la prima pagina.
- **Pagine** bianche, a puntini, a quadretti, a righe, a righe strette, Cornell, elenco con
  caselle o pentagramma; carta bianca, avorio, gialla o grigia; A4 verticale/orizzontale,
  Lettera o quadrato. Griglia delle pagine per saltare, duplicare, spostare o eliminare.
- **Barra strumenti** sempre in vista: penna, matita, evidenziatore, gomma (tratto intero,
  piccola, grande), lazo, mano per spostare testi e foto, righello; tre spessori e tre colori
  per strumento più un colore a scelta, ricordati tra un quaderno e l'altro. Zoom a due dita,
  annulla/ripeti. Su iPad si può scrivere solo con la Pencil e scorrere col dito.
- **PDF**: importa un PDF come nuovo quaderno (anche con "Apri con" dall'app File) o aggiungine
  le pagine a un quaderno esistente, e scrivici sopra. Un quaderno si crea anche da foto.
- **Testo e foto** sulla pagina: riquadri di testo (dimensione, grassetto, colore) e immagini,
  da trascinare e ridimensionare.
- **Ricerca** nei titoli, nella scrittura a mano (riconosciuta sul dispositivo con Vision, in
  italiano e inglese), nei riquadri di testo e nel testo dei PDF.
- **Esporta** il quaderno o una pagina in PDF, da condividere o salvare in File.

## iCloud Drive

In *Impostazioni → iCloud Drive* si sceglie una cartella (per esempio una nuova cartella
«Appunti» in iCloud Drive): l'app ci copia i quaderni dopo averne chiuso uno e quando va in
secondo piano, oppure con *Salva adesso*. Su un altro iPhone o iPad si sceglie la stessa
cartella e si tocca *Ripristina*.

La sincronizzazione iCloud automatica di Apple richiede un account sviluppatore a pagamento e
non funziona con le app installate con Feather o Sideloadly; una cartella scelta in File invece
funziona sempre. I quaderni restano comunque anche sul dispositivo, in
*File → Sul mio iPhone → Appunti → Quaderni*.

## Compilare

Nessun Mac necessario: `.github/workflows/ipa.yml` genera il progetto con XcodeGen e produce
`Appunti-<versione>-unsigned.ipa` (artefatto `appunti-ipa`), da installare con Feather,
Sideloadly o AltStore. Nuova versione: aumentare `MARKETING_VERSION` in `project.yml`.

Le schermate qui sopra le fa `.github/workflows/screenshots.yml` (avvio manuale): compila per il
simulatore e lancia `scripts/screenshots.sh`, che apre l'app con `-demo -screen <nome>` su un
iPhone e un iPad con dei quaderni d'esempio.
