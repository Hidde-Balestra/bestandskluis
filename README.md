# Bestandskluis

Android-app (Flutter) die een bestandsbeheerder, foto- en videogalerij, FTP-server en versleutelde mappen combineert.

[![CI](https://github.com/Hidde-Balestra/bestandskluis/actions/workflows/ci.yml/badge.svg)](https://github.com/Hidde-Balestra/bestandskluis/actions/workflows/ci.yml)
[![Release](https://github.com/Hidde-Balestra/bestandskluis/actions/workflows/release.yml/badge.svg)](https://github.com/Hidde-Balestra/bestandskluis/releases/latest)

**Download:** de nieuwste getekende APK staat bij [Releases](https://github.com/Hidde-Balestra/bestandskluis/releases/latest).

## Functies

### Bestanden
- Bladeren door interne opslag en SD-kaart, met snelkoppelingen (Downloads, Camera, …)
- Lijst- en galerijweergave, verborgen bestanden tonen
- Kopiëren, knippen/plakken, hernoemen, verwijderen, nieuwe map, delen
- Meerdere items selecteren (lang indrukken)

### Galerij
- Alle foto's en video's van het toestel per album
- Viewer met zoomen, vegen en een videospeler
- **Naar kluis verplaatsen**: selecteer foto's/video's, versleutel ze in een kluis en verwijder ze uit de galerij
- Tabblad **Kluizen**: foto's en video's uit ontgrendelde kluizen

### Versleutelde mappen (kluizen)
- Elke map kan een kluis worden: **Map versleutelen** in het menu van de map
- Bestanden in de kluis (ook in submappen) worden opgeslagen als `naam.ext.bkv`
- Ontgrendelen met een wachtwoord; de sleutel staat alleen in het werkgeheugen
- Bestanden die je in een kluis plakt worden automatisch versleuteld; bestanden die je eruit haalt automatisch ontsleuteld
- Automatisch vergrendelen na 5 minuten op de achtergrond (behalve als de FTP-server draait)
- **Delen = tijdelijk ontsleutelen**: bij delen wordt een ontsleutelde kopie in de cache van de app gemaakt. Die wordt na 10 minuten verwijderd, en in elk geval bij de volgende start van de app. De kluis zelf blijft versleuteld.

### FTP
- **Eigen FTP-server** op je toestel: kies de gedeelde map, poort, gebruiker/wachtwoord (willekeurig gegenereerd), alleen-lezen of anoniem
- **Kluizen via FTP**: bestanden in *ontgrendelde* kluizen worden tijdens het downloaden ontsleuteld (`foto.jpg.bkv` verschijnt als `foto.jpg`). Uploads naar een kluis worden direct versleuteld opgeslagen. Op de schijf wordt nooit iets ontsleuteld bewaard. Vergrendelde kluizen geven alleen de versleutelde `.bkv`-bestanden en weigeren uploads.
- **FTP-client**: verbinden met andere servers, bladeren, downloaden, uploaden (ook vanuit een kluis, dan wordt het tijdelijk ontsleuteld), hernoemen en verwijderen
- Ondersteunt passief (PASV/EPSV) en actief (PORT), MLSD/LIST, SIZE, MDTM, REST (hervatten, ook bij ontsleutelen)

> FTP versleutelt het netwerkverkeer niet. Gebruik de server alleen op een vertrouwd netwerk.

## Beveiliging

| Onderdeel | Keuze |
|---|---|
| Sleutel uit wachtwoord | PBKDF2-HMAC-SHA256, 210.000 iteraties, 16-byte salt per kluis |
| Sleutel per bestand | HKDF-SHA256(kluissleutel, willekeurige salt van 16 bytes) |
| Versleuteling | AES-256-GCM in blokken van 256 KiB (streaming, ook voor grote video's) |
| Integriteit | GCM-tag per blok; de AAD bevat de header en een "laatste blok"-vlag, zodat wijzigen, omwisselen of afkappen wordt herkend |
| Wachtwoordcontrole | AES-GCM-gecodeerde controlewaarde in `.bestandskluis` |

Bestandsnamen en de mapstructuur blijven zichtbaar; alleen de inhoud is versleuteld. Zonder het wachtwoord is een kluis **niet** te herstellen.

Bestandsformaat (`.bkv`, versie 1): `"BKV1"` · blokgrootte (u32) · salt (16 bytes), daarna blokken `AES-GCM(blok) || tag(16)` met nonce = bloknummer.

## Ontwikkelen

```bash
flutter pub get
flutter analyze
flutter test           # crypto, kluizen, FTP-server en -client
flutter run
```

Een lokale release-build heeft `android/key.properties` nodig (zie hieronder). Voor een snelle test zonder sleutel: `flutter build apk --debug`.

## Releases en signing

Releases worden gebouwd door GitHub Actions ([release.yml](.github/workflows/release.yml)):

```bash
# versie in pubspec.yaml aanpassen, dan:
git tag v1.0.1
git push origin v1.0.1
```

De workflow test de code, bouwt de APK, tekent hem met de release-sleutel, controleert de handtekening met `apksigner` en publiceert een GitHub-release met de APK en `SHA256SUMS.txt`.

**Signing**
- De release-sleutel staat als repository-secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
- De repo-variabele `ANDROID_CERT_SHA256` bevat de verwachte vingerafdruk van het certificaat. De release faalt als de APK met een andere sleutel (of de debug-sleutel) is getekend.
- Ontbreken de secrets, dan faalt de release. Ook Gradle weigert een release-build zonder `android/key.properties`.
- Certificaat SHA-256: `86:A8:2A:37:DB:38:3C:C8:FB:1D:0C:EC:A0:18:A2:7B:D9:B5:9C:A5:47:9F:8A:A0:97:21:FE:EA:DE:22:61:F1`

Lokaal staan `android/key.properties` en `android/app/upload-keystore.jks` (beide in `.gitignore`). **Bewaar een back-up van deze twee bestanden.** Zonder dezelfde sleutel kunnen bestaande installaties niet meer worden bijgewerkt.
