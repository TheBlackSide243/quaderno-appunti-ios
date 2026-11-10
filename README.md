# Appunti

App per iPhone e iPad (SwiftUI, iOS 17+) per prendere appunti a mano, nello stile dei quaderni
digitali: Apple Pencil o dito, quaderni con copertina, PDF da annotare e ricerca nella scrittura.

## Cosa fa

- **Quaderni** con copertina colorata (o la prima pagina), cartelle, preferiti, duplica, rinomina.
- **Pagine** bianche, a righe, a quadretti, a puntini o Cornell, carta bianca/avorio/grigia,
  formato A4 verticale/orizzontale, Lettera o quadrato. Griglia delle pagine per saltare,
  duplicare, spostare, cambiare modello o eliminare.
- **Scrittura** con gli strumenti di PencilKit: penna, matita, pennarello, evidenziatore, gomma,
  lazo per spostare il tratto, righello, colori. Zoom con due dita, annulla/ripeti.
  Su iPad si può scegliere di disegnare solo con la Pencil e scorrere col dito.
- **PDF**: importa un PDF come nuovo quaderno (anche da "Apri con" nell'app File) o aggiungi
  le sue pagine a un quaderno esistente, e scrivici sopra.
- **Testo e foto** sulla pagina: riquadri di testo (dimensione, grassetto, colore) e immagini
  dalla libreria, da trascinare e ridimensionare.
- **Ricerca** nei titoli, nella scrittura a mano (riconosciuta sul dispositivo con Vision, in
  italiano e inglese), nei riquadri di testo e nel testo dei PDF.
- **Esporta** il quaderno o una pagina in PDF, da condividere o salvare in File.

I quaderni restano sul telefono, in *File → Sul mio iPhone → Appunti → Quaderni*, da dove si
possono copiare per backup.

## Compilare

Nessun Mac necessario: `.github/workflows/ipa.yml` genera il progetto con XcodeGen e produce
`Appunti-<versione>-unsigned.ipa` (artefatto `appunti-ipa`), da installare con Feather,
Sideloadly o AltStore. Nuova versione: aumentare `MARKETING_VERSION` in `project.yml`.
