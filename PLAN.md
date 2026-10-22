# Clocking — plan de lucru (aprobat 22.10.2026)

Aplicație de pontaj pentru cabinete și afaceri locale mici, cu câțiva angajați.
Locală, fără internet, fără server, fără conturi. Android. Română + engleză.

## Funcții de bază (specifice aplicației)

1. **Angajați** — adăugați manual de manager (nume, funcție, telefon opțional,
   notă); editare, dezactivare (istoricul rămâne), ștergere.
2. **Cod QR per angajat** — generat după înregistrare (`CLK1:<id>:<secret>`).
   Se printează (PDF cu carduri) sau se trimite ca imagine angajatului. Poate
   fi regenerat (codul vechi devine invalid).
3. **Pontaj prin scanare** — un singur dispozitiv (telefon/tabletă la intrare)
   scanează codul printat sau afișat pe telefonul angajatului. Angajații NU au
   aplicația. Scanarea alternează intrare/ieșire; dubla scanare în câteva
   minute e ignorată; corectură rapidă imediat după scanare. Corecturi
   manuale ale managerului, marcate ca atare. Zona de manager protejată cu PIN.
   Fără fotografii.
4. **Grafic de lucru** — generat după selecția managerului:
   - program fix (zile din săptămână + o tură);
   - ture rotative (2 sau 3 ture, rotație la N zile);
   - cicluri continue: 12/24, 12/48, 24/48, 24/72 sau ciclu personalizat;
   - număr și ore ture configurabile; zile libere; concedii (odihnă, medical,
     fără plată, alt motiv); opțional sărbătorile legale din România.
   Vizualizare calendar pe lună, modificare manuală pe zile, export PDF/CSV.
5. **Rapoarte** — perioadă aleasă, un angajat sau toți: intrări/ieșiri pe zile,
   ore lucrate, întârzieri și plecări devreme față de grafic, ore suplimentare,
   absențe, concedii, pontaje incomplete. Export PDF și CSV (Excel).

## Funcții comune (copiate din tiparul aplicațiilor Volt Academy — pensiune_app)

- Două limbi (`l10n.dart` — `tr(ro, en)`, `AppLang.kt`), alegere din iconița glob.
- Licență: trial 30 zile, apoi fișier semnat RSA legat de codul de instalare
  (`clocking-<timestamp>`), ceas protejat, avertizare expirare, ecran Licență.
  Cheie RSA nouă: `D:\ClockingLicenseTool` + `volt-academy-license-tools/clocking`.
  După trial fără licență: scanarea continuă (nu se pierd date), dar adăugarea
  de angajați, generarea graficului și rapoartele sunt blocate.
- Sincronizare pe două telefoane prin SMS, semnată cu cod de împerechere
  (`SyncAuth`, `SmsSyncReceiver`, coadă nativă). Licența acoperă ambele
  telefoane și se transmite prin SMS.
- Backup criptat (AES-256-GCM, parolă), manual + automat zilnic, pe telefon sau
  stick USB; restaurare.
- Open source AGPL-3.0-or-later, README în engleză, `tools/generate_license.js`.
- Offline complet: permisiunea INTERNET eliminată în release, telemetria ML Kit
  dezactivată (ca la Inventar+).
- Teste Flutter + teste JVM pentru logica nativă.

## Site voltacademy_web

Produs nou `clocking`, exact ca la LocalEventPRO: `lib/products.js`,
`clocking.html`, `js/clocking.js`, ghid, carduri de produs, software.html,
footere, sitemap, termeni, confidențialitate, pagina de succes, recenzii,
analytics, Supabase (schema + migrare), teste. Commit local — publicarea
(push / deploy / variabila `LICENSE_PRIVATE_KEY_PEM_CLOCKING`) după confirmare.

## Livrare

`flutter analyze`, teste, APK release semnat cu keystore propriu
(`C:\Users\AdyPt\clocking-release.jks`), trimis utilizatorului.
