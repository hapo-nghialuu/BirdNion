<div align="center">
  <img src="docs/social.png" alt="BirdNion - AI quota companion for macOS and Linux" />
</div>

# BirdNion - Damit deine KI-Agents im Budget bleiben.

> Alle KI-Coding-Kontingente und Agent-Einstellungen in deiner macOS-Menüleiste oder im Linux-Infobereich.

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · **Deutsch** · [Français](README.fr.md)


[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-fcc624?style=flat-square&logo=linux&logoColor=111)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

38 Anbieter. BirdNion ist eine kleine Menüleisten-App für macOS 14+ und eine App für den Linux-Infobereich. Sie hält KI-Coding-Limits im Blick, zeigt, wann jedes Zeitfenster zurückgesetzt wird, und bündelt die Auswahl der Datenquellen für jeden Coding-Agent. Codex, Claude, MiniMax, OpenRouter, DeepSeek, z.ai, ElevenLabs, Deepgram, Groq, Grok, xAI, OpenAI, Ollama, GitHub Copilot, Kilo, Command Code, Xiaomi MiMo, Alibaba/Qwen, Cursor, Gemini, Kiro, OpenCode, OpenCode Go, Antigravity, AWS Bedrock, FreeModel, Devin und Hapo AI Hub — dazu Anbieter über JavaScript-Plugins (Aixy, Atlas Cloud, ClinePass, LiteLLM, Muse Code, Nous Portal, Raycast, Sakana AI, Venice, xKiro).

Die native macOS-App nutzt SwiftUI/AppKit und einen eingebundenen, reduzierten Teil von `CodexBarCore`. Die Linux-Portierung liegt in `linux/` und verwendet Tauri v2 mit einem Rust-Kern und einer Oberfläche in reinem TypeScript. Beide Plattformen nutzen dasselbe XDG-Schema für die Anbieterkonfiguration.

## Warum BirdNion?

- **Resets einplanen.** Anbieterbezogene 5-Stunden-, Wochen-, Monats-, Guthaben- und Budgetfenster mit Reset-Countdowns.
- **Ausgaben und Kosten sehen.** Lokale JSONL-Scans für Claude, wöchentliche Nutzungsauswertungen, datenschutzfreundliche Projektranglisten, Diagramme der Claude Admin API, Codex-Guthaben, OpenRouter-Kontostände, Bedrock-Budgets sowie anbieterspezifische Kosten- und Guthabenübersichten, soweit verfügbar.
- **Agent-Quellen konfigurieren.** Wähle in den Einstellungen je Anbieter zwischen OAuth, CLI, Browser-Cookies, API-Schlüsseln, AWS-Zugangsdaten, lokalen App-Dateien oder Anbieter-Apps.
- **Wechseln, ohne den Kontext zu verlieren.** macOS und Linux bieten beide den Wechsel zwischen benutzerdefinierten Claude-/Codex-Profilen, Codex-Reset-Guthaben/Auto-Prime sowie Abläufe für mehrere Konten bei Codex, Copilot, Antigravity und FreeModel.
- **Die Desktop-Oberfläche dezent halten.** Auf macOS kann BirdNion abwechselnd die Kontingent-Prozentwerte der Anbieter in der Menüleiste anzeigen; unter Linux wechseln Anbieterlogo und Prozentwert direkt im Symbol des Infobereichs.
- **Datenschutz zuerst.** BirdNion verwendet bestehende Sitzungen und ausdrücklich festgelegte Konfigurationen. Es speichert keine Passwörter und durchsucht die Festplatte nicht uneingeschränkt.

## Installation

### Voraussetzungen

- macOS 14+ (Sonoma)
- Linux x86_64 für die veröffentlichten `.deb`-, `.rpm`- und `.AppImage`-Pakete

### GitHub Releases

Lade fertige Pakete von [GitHub Releases](https://github.com/hapo-nghialuu/BirdNion/releases) herunter:

- `BirdNion-<version>.zip` - Universal-App für macOS, mit Developer ID signiert und von Apple notarisiert.
- `BirdNion_<version>_amd64.deb` - Paket für Ubuntu/Debian.
- `BirdNion-<version>-1.x86_64.rpm` - Paket für Fedora/RHEL.
- `BirdNion_<version>_amd64.AppImage` - Portables Linux-Paket.
- Der Homebrew-Cask verwendet SHA256.
- Das Notarisierungsticket ist an die App angeheftet. Gatekeeper öffnet sie daher nach der üblichen Bestätigung „aus dem Internet geladen“ direkt — auch offline.

### macOS über Homebrew

Empfohlener Installationsbefehl:

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

Der vollständig qualifizierte Befehl wählt ausdrücklich `hapo-nghialuu/tap/birdnion` aus. Ein separater Schritt mit `brew tap` ist daher nicht nötig.

Installation mit Kurznamen nach dem Hinzufügen des Taps:

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

Oder vertraue dem gesamten Tap:

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

Verwende `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` nicht als regulären Installationsweg. Diese Umgebungsvariable überschreibt die Einstellung auf Benutzerseite und kann nicht in `Casks/birdnion.rb` gesetzt werden, um die Vertrauensprüfung zu umgehen, bevor Homebrew den Cask lädt.

### macOS-Version aktualisieren

```bash
brew update && brew upgrade --cask birdnion
```

Führe zuerst `brew update` aus, mit `&&` verknüpft, damit der Tap den neuesten Cask abruft —
`brew upgrade` allein aktualisiert einen Drittanbieter-Tap nicht und meldet bei einer veralteten Version
„bereits installiert“.

Installierte Version prüfen:

```bash
brew list --cask --versions birdnion   # or: brew info --cask birdnion
```

### Linux

Lade eines der Linux-Pakete aus [der neuesten Version](https://github.com/hapo-nghialuu/BirdNion/releases/latest) herunter:

```bash
sudo apt install ./BirdNion_<version>_amd64.deb
# or
sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# or
chmod +x BirdNion_<version>_amd64.AppImage
./BirdNion_<version>_amd64.AppImage
```

### Erster Start

- Öffne BirdNion über die macOS-Menüleiste oder den Linux-Infobereich.
- Öffne Einstellungen -> Anbieter und aktiviere die Anbieter, die du nutzt.
- Installiere die benötigten Anbieterquellen oder melde dich dort an: je nach Anbieter CLIs, Browser-Sitzungen, OAuth/Geräteautorisierung, API-Schlüssel, lokale App-Dateien oder Cloud-Zugangsdaten.
- Optional: Lege Kontobezeichnungen, Sichtbarkeit in der Menüleiste, Aktualisierungsintervalle, Cookie-Quelle, Region, AWS-Authentifizierungsmodus, Kilo-Organisationsbereich, Copilot-Enterprise-Host oder die anbieterspezifische Menüleistenkennzahl fest.

## Einstellungen und Konfiguration für Agents

BirdNion soll eine schlanke Einstellungs- und Konfigurationskonsole für KI-Coding-Agents werden, nicht nur eine Kontingentanzeige.

Bereits verfügbar:

- Anbieteraktivierung, Reihenfolge, Kontobezeichnungen, Aktualisierungsintervalle und Sichtbarkeit in der Menüleiste.
- Quellenauswahl für Anbieter, die OAuth, CLI, Browser-Cookies, Admin API oder lokale App-Zustände auslesen können.
- Anbieterspezifische Einstellungen für Cookie-Modus, manuelle Cookie-Header, MiniMax-/z.ai-/Alibaba-Regionen, AWS-Schlüssel/-Profile/-Regionen, Deepgram-Projekt-ID, Kilo-Organisationsbereich, Copilot-Enterprise-Host und die Auswahl der Menüleistenkennzahl.
- Erkennung lokaler Sitzungen von Agents, die ihren Authentifizierungszustand selbst verwalten: Claude Code, Codex CLI, Gemini CLI, Kiro, Cursor, Antigravity und ähnliche Tools.
- Eine Claude Code-Konfigurationskonsole für vordefinierte oder eigene Backends, Modellstufen, globalen oder projektbezogenen Geltungsbereich, JSON-Import und das sichere Entfernen von BirdNion verwalteter Umgebungsschlüssel.
- Wechsel zwischen benutzerdefinierten Claude Code- und Codex-Profilen mit tatsächlicher Prüfung auf Bereitschaft, veralteten Zustand und Proxy-Funktion sowie einer Aktivierung, die bei Fehlern gesperrt bleibt.
- Erkennung mehrerer Konten und Kontowechsel für Codex, GitHub Copilot, Antigravity und FreeModel, einschließlich browserbezogener FreeModel-Sitzungen.

Geplante Richtung:

- Profilverwaltung über Claude Code hinaus auf weitere Coding-Agents ausweiten.
- Ausführlichere Informationen zum Anmelde- und Quellenstatus jedes Agents anzeigen.
- Lokale Konfigurationspfade und CLI-Verfügbarkeit prüfen.
- Einrichtungshinweise für Claude Code, Codex CLI, Gemini CLI, Kiro und künftige Agents bereitstellen.
- BirdNion-Einstellungen in der eigenen Konfigurationsebene belassen und den Zugangsdaten-Speicher jedes Agents unverändert lassen.

## Anbieter

- **Codex** - OAuth API aus `~/.codex/auth.json`, API-Schlüssel als Fallback, lokaler `codex app-server` als Fallback, Dienststatus, Version, Guthaben, Reset-Guthaben, optionale OpenAI-Web-Extras und verwalteter Kontowechsel.
- **Claude** - OAuth API, Browser-Cookies, CLI oder Admin API; 5-Stunden-/Wochen-/Opus-/Sonnet-Fenster, tägliche Routinen, lokale Kostenscans, Web-Extras (Ausgaben für zusätzliche Nutzung und verbleibendes Prepaid-Guthaben) sowie ein 30-Tage-Administratordiagramm. Max-Tarife zeigen ihren Nutzungsmultiplikator (Max 5x / Max 20x).
- **MiniMax** - API-Token, Token aus der Umgebung oder Cookie-Fallback für die Nutzung des Coding-Tarifs, Tarifname, Punkte/Abonnement und globale/CN-Region.
- **OpenRouter** - API-Token für Prepaid-Guthaben und ein optionales Ausgabenlimit je Schlüssel.
- **DeepSeek** - API-Token für USD-/CNY-Guthaben mit Aufteilung in bezahltes und gewährtes Guthaben sowie Warnung bei niedrigem Kontostand.
- **z.ai** - API-Token mit globaler/CN-Region für Kontingentlimits und berechneten verbleibenden Prozentwert.
- **ElevenLabs** - API-Schlüssel für Zeichenguthaben, Stimmplätze, professionelle Stimmen, Tarif und Abonnementstatus.
- **Deepgram** - API-Schlüssel mit optionaler Projekt-ID für Nutzungsübersichten und einen Modus zur Zusammenfassung aller Projekte.
- **Groq** - API-Schlüssel für auf Prometheus basierende Kennzahlen zu Anfragen, Tokens und Cache-Treffern.
- **Grok** - Ohne Konfiguration aus `~/.grok/auth.json` (`grok login`); zuerst CLI-RPC über `x.ai/billing`, dann grok.com-Abrechnung per gRPC-web über Chrome-Cookies / Auth-Bearer; SuperGrok-Identität und Guthabenfenster. Lokale Kosten im Tab Alle aus `~/.grok/sessions/**/signals.json` (Token-Summen × Tabelle gemittelter Modellpreise).
- **xAI** - Management-API-Schlüssel und Team-ID für die Entwicklerplattform (getrennt vom Grok-Endkundenabonnement); Prepaid-Guthaben und Plattformausgaben über 30 Tage.
- **OpenAI** - Platform Admin API (`OPENAI_ADMIN_KEY` / Konfiguration) für Organisationsausgaben heute/7 Tage/30 Tage; optionale Projekt-ID; älterer Credit-Grants-Fallback für Benutzer-API-Schlüssel. Nicht für ChatGPT-/Codex-Abonnements (dafür Codex verwenden).
- **Ollama** - Cloud-Nutzung pro Sitzung/Woche über ollama.com-Cookies (Automatisch/Manuell); optional prüft `OLLAMA_API_KEY` den Zugriff auf die Cloud API.
- **GitHub Copilot** - GitHub-Geräteautorisierung oder PAT-Fallback, Enterprise-Host, vollständige Kontoverwaltung mit Hinzufügen/Wechseln/Entfernen, Premium-Nutzung, Benutzername und zusätzliche Budgetinformationen über Web-Cookies.
- **Kilo** - API-Token oder CLI-Sitzung, Kilo-Organisationsbereich, Guthaben und Details zur automatischen Aufladung.
- **Kiro** - CLI-basierte Nutzung, Daten zu Guthaben/Mehrverbrauch und 9 Anzeigemodi für die Menüleiste.
- **Command Code** - Browser-Cookies oder manuell angegebene Cookies für Abrechnungsguthaben und Tarifkatalog.
- **Xiaomi MiMo** - Browser-Cookies für Guthaben, Token-Tarifdetails und Nutzung.
- **Alibaba/Qwen** - Browser-Cookies sowie internationale/CN-Region für die Fenster von Coding- und Token-Tarifen.
- **Cursor** - Zuerst Cursor `state.vscdb`, Browser-Cookies als Fallback, Nutzungsübersicht, Identität und Anfrageverbrauch.
- **Gemini** - Gemini CLI-OAuth-Zugangsdaten aus `~/.gemini/oauth_creds.json` für die Kontingentstufen von Cloud Code Assist.
- **OpenCode** - Browser-Cookies für rollierende/wöchentliche Nutzung und Abonnementverlängerung.
- **OpenCode Go** - Browser-Cookies und Go-Workspace-Seite für rollierende/wöchentliche/monatliche Nutzung und Zen-Guthaben.
- **Antigravity** - Lokale Prozess-/CLI-Prüfung und Google OAuth-Kontospeicher für Kontingentgruppen und dem Konto zugeordnete Daten.
- **AWS Bedrock** - AWS-Zugriffsschlüssel oder benanntes Profil, Region, Budgetfelder und CloudWatch-/Kostennutzung.
- **FreeModel** - Browser-Sitzungen von `freemodel.dev` für 5-Stunden- und wöchentliche Dollarbudgets, mit browserbezogenem Kontowechsel und Unterstützung für verwaltete Cookies.
- **Devin** - Tägliches und wöchentliches Kontingent von `app.devin.ai/api/<org>/billing/quota/usage`. Importiert Browser-Sitzungstoken und Organisation automatisch aus Chrome localStorage oder verwendet einen manuellen Bearer-Token mit optionaler Organisation (Slug oder interne `org-...`-ID).

Weitere Anbieter sind willkommen, wenn sie in das bestehende `QuotaProvider`-Modell passen.

## Maskottchen, Symbol und Screenshots

Standardmäßig zeigt die macOS-Menüleiste den BirdNion-Vogel. Wenn „Prozent in der Menüleiste anzeigen“ aktiviert ist, wechselt die Leiste zwischen den Kontingent-Prozentwerten aktiver Anbieter und deren Logos. Unter Linux erscheinen das wechselnde Anbieterlogo und der Prozentwert direkt im Symbol des Infobereichs.

<div align="center">
  <img src="website/assets/birdnion-readme-bird-quota-384.png" width="196" alt="BirdNion mascot holding a blue and yellow quota bar" />
  <br />
  <strong>BirdNion-Kontingent-Begleiter</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/logo.png" width="112" alt="BirdNion app icon" />
  <br />
  <strong>BirdNion-App-Symbol</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/usage-overview.png" width="426" alt="BirdNion usage and cost overview" />
  <br />
  <strong>Nutzungs- und Kostenübersicht</strong>
</div>

<br />

<div align="center">
  <img src="website/assets/control-surface-redraw.jpg" width="776" alt="Illustrated BirdNion Linux control surface based on the current Settings implementation" />
  <br />
  <strong>Bedienoberfläche · illustriert auf Basis der aktuellen Linux-Einstellungen</strong>
</div>

## Funktionen

- Optionale wechselnde Anbieterwerte in der macOS-Menüleiste oder im Linux-Infobereich, mit Anbieterschaltern und plattformgerechter Bedienung zum Ändern der Reihenfolge.
- Anbieterspezifische Verbrauchsanzeigen mit Reset-Countdowns.
- Die geführte Einrichtung führt bei behebbaren Anbieterfehlern direkt zum passenden Bedienelement in den Einstellungen, speichert zuerst und markiert den Anbieter erst dann als live, wenn ein tatsächlicher Selbsttest erfolgreich war.
- Ein kompaktes Aktionszentrum-Badge in der Popover-Kopfzeile öffnet die Einstellungen bei aktuellen Einrichtungs- oder Verbindungsproblemen. Behobene Probleme verschwinden automatisch; es wird kein Problemverlauf gespeichert.
- Schrittweise Aktualisierung: Jeder Anbieter veröffentlicht seine Daten, sobald der Abruf abgeschlossen ist.
- Die zuletzt bekannten Daten bleiben während laufender Aktualisierungen sichtbar.
- Anbieter-Quellenauswahl für OAuth, CLI, Web-Cookies, Admin API, lokale App-Zustände und statische Schlüssel.
- Aktualisierungsintervalle und Sichtbarkeit in der Menüleiste je Anbieter.
- Cookie-Quellenauswahl mit den Modi Automatisch, Manuell und Aus für Cookie-basierte Anbieter.
- Lokale Kostendiagramme für 17 Agent-Quellen — Claude, Codex, Grok, Kiro, Oh My Pi, Pi, Devin, OpenCode, Gemini CLI, Copilot CLI, Antigravity, Cursor, Amp, Droid, Kimi, Qwen Code und Goose — mit dauerhaft gespeichertem Höchststandsverlauf. Gespeicherte Balken werden sofort angezeigt, während ein enger begrenzter Live-Scan die letzten Tage aktualisiert.
- Eine kompakte Auswertung im Tab Alle öffnet Einstellungen -> Auswertungen für 7-Tage-Vergleiche und Projektranglisten über 7/30/90 Tage. Claude, Codex und Grok leiten datenschutzfreundliche Projektidentitäten aus ihren lokalen Sitzungsmetadaten ab; nur die nicht zuordenbare Restnutzung bleibt ausdrücklich `Unknown`.
- 30-Tage-Diagramm der Claude Admin API und Extras des Codex-Web-Dashboards, sofern aktiviert.
- Eigene Kiro-Anzeigewerte: verbleibendes Guthaben, Prozentwert, verbraucht/gesamt und Mehrverbrauchsmodi.
- Benachrichtigungen zu Kontingenten und Anbieterausfällen mit konfigurierbaren Schwellenwerten.
- XDG-Konfigurationsdatei mit restriktiven Berechtigungen.

## Konfiguration und Speicherung

| Daten | Speicherort |
|---|---|
| Anbieterliste, Aktivierungsstatus, API-Schlüssel, Region, Budget, Projekt-ID, Basis-URL, Kontobezeichnung | `~/.config/birdnion/settings.json` |
| Abweichender Konfigurationspfad | `$BIRDNION_CONFIG` |
| Abweichender XDG-Pfad | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| Ältere Konfiguration | `~/.birdnion/settings.json` |
| Codex OAuth | `~/.codex/auth.json`, von Codex CLI verwaltet |
| Claude OAuth | macOS-Keychain-Eintrag `Claude Code-credentials`; Linux `~/.claude/.credentials.json`; beide von Claude Code/CLI verwaltet |
| Gemini OAuth | `~/.gemini/oauth_creds.json` |
| Cursor-Sitzung | macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`; Linux: `~/.config/Cursor/User/globalStorage/state.vscdb` |
| Antigravity OAuth-Konten | `~/.config/birdnion/antigravity-oauth.json` |
| Copilot OAuth-Konten | `~/.config/birdnion/copilot-accounts.json` |
| Verwaltete FreeModel-Konten | macOS: `~/Library/Application Support/BirdNion/freemodel-accounts.json`; Linux: `~/.config/birdnion/freemodel-accounts.json` |
| Täglicher Kostenverlauf (Tab Alle) | `~/.config/birdnion/cost-history.json` (neben der Einstellungsdatei; Zusammenführung nach Höchstständen, damit vergangene Balken auch bei gelöschten Agent-Sitzungen erhalten bleiben) |
| Projektkostenverlauf (Auswertungen) | `~/.config/birdnion/project-cost-history.json` (separater optionaler Speicher; SHA-256-Projektschlüssel/Rücknahme-IDs, sichere Basisnamen, durch Gesamtsummen begrenzte Höchststands-Zusammenführung, `0600`) |
| macOS-Oberflächeneinstellungen | `UserDefaults` (`showPercentInMenuBar`, Sichtbarkeit, Aktualisierung, Quellen- und Anzeigeeinstellungen) |
| Linux-Oberflächeneinstellungen | Tauri WebView `localStorage`; Cookie-/Sichtbarkeits-/Aktualisierungsfelder der Anbieter bleiben in `settings.json` |

Priorität der Konfigurationspfade:

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

Die Konfigurationsdatei wird atomar geschrieben und erhält die Berechtigung `0600`.

## Datenschutzhinweis

BirdNion durchsucht das Dateisystem nicht uneingeschränkt. Es liest nur dokumentierte Speicherorte, wenn der zugehörige Anbieter bzw. die Quelle aktiviert ist: Anbieter-Konfigurationsdateien, CLI-Authentifizierungsdateien, Browser-Cookie-Speicher, lokale IDE-Datenbanken und lokale Agent-Sitzungsprotokolle. Anbieter-Token liegen in der BirdNion-Konfigurationsdatei mit restriktiven Berechtigungen. OAuth-, Keychain- und CLI-Sitzungsdateien werden weiterhin von ihren ursprünglichen Tools verwaltet.

Es werden keine Passwörter gespeichert. Browser-Cookies werden nur wiederverwendet, wenn der Benutzer eine Cookie-basierte Quelle auswählt. Die Auswertungen speichern niemals einen vollständigen Projektpfad: Claude hasht das stabile Token seines Sitzungsverzeichnisses, Codex einen validierten absoluten `cwd` und Grok das kodierte Token seines Sitzungsverzeichnisses. Verifizierte Pfade dürfen nur zur Verbesserung der bereinigten Basisnamen-Bezeichnung dienen; die Oberfläche und die kopierbare Zusammenfassung erhalten diese sichere Bezeichnung oder eine ausdrückliche Restkategorie `Unknown`.

## Plattformhinweise

### macOS-Berechtigungen

- **Festplattenvollzugriff** - für die Kernfunktionen der App nicht erforderlich. Anbieter mit Browser-Cookies benötigen je nach Browser und Cookie-Speicher möglicherweise zusätzlichen macOS-Zugriff.
- **Keychain-Zugriff** - Claude OAuth kann den von Claude Code/CLI verwalteten Eintrag `Claude Code-credentials` auslesen; auch der Import von Browser-Cookies kann Keychain-Abfragen für den Safe Storage des Browsers auslösen.
- **Abfragen für Dateien und Ordner** - lokale Anbieterprüfungen können macOS-Abfragen auslösen, wenn die zugrunde liegende CLI oder ein Hilfsprogramm auf geschützte Speicherorte zugreift.
- **Was BirdNion nicht im Hintergrund anfordert** - keine Berechtigung für Bildschirmaufnahme oder Bedienungshilfen.

### Linux

- Anbieter mit Browser-Cookies benötigen ein unterstütztes Chrome-/Chromium-/Brave-/Edge-/Firefox-Profil und können vom Schlüsselbund der Desktop-Umgebung abhängen.
- Im Infobereich erscheinen das wechselnde Anbieterlogo und der Prozentwert direkt im Symbol, da Linux-Desktops keine plattformübergreifend einheitliche Textanzeige neben solchen Symbolen bieten.
- Globale Hotkeys sind unter Linux nicht aktiviert; nutze das App-Fenster und die Bedienelemente in den Einstellungen.

## Dokumentation

- [docs/build.md](docs/build.md) - Build, Signierung und Fehlerbehebung.
- [docs/system-architecture.md](docs/system-architecture.md) - Systemarchitektur und historisches Entscheidungsprotokoll.
- [docs/development-roadmap.md](docs/development-roadmap.md) - Historische Roadmap.
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - Funktionsvergleich von BirdNion und CodexBar.
- [docs/linux-parity-matrix.md](docs/linux-parity-matrix.md) - Funktionsgleichstand zwischen macOS und Linux.
- [linux/README.md](linux/README.md) - Linux-Entwicklung, Paketierung und Plattformhinweise.

## Einstieg für Entwickler

- Klone das Repository. Öffne `BirdNion.xcodeproj` für macOS oder arbeite für die Tauri-Entwicklung in `linux/`.
- Starte die App einmal und schalte dann unter Einstellungen -> Anbieter die gewünschten Anbieter ein.
- Installiere die benötigten Anbieterquellen oder melde dich dort an: CLIs, Browser-Cookies, OAuth/Geräteautorisierung, API-Schlüssel, Anbieter-Apps oder lokale Konfigurationsdateien.
- Optional: Richte OpenAI-Cookies für Codex-Dashboard-Extras und die Claude-Quellenauswahl für OAuth/Web/CLI/Admin API ein.

## Aus dem Quellcode bauen

### macOS

Erfordert macOS 14+ und Xcode mit Swift-Unterstützung für das Projektschema.

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion bindet ein reduziertes `CodexBarCore`-Paket unter `Vendor/CodexBar` ein; ein externer Checkout unter `~/Desktop/CodexBar` ist nicht erforderlich.

### Linux

Entwicklung und Tests können aus `linux/` unter macOS oder Linux ausgeführt werden. Native Linux-Pakete müssen unter Linux mit installierten WebKitGTK-/AppIndicator-Abhängigkeiten gebaut werden.

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml

# On Linux: build .deb, .rpm, and AppImage bundles
npm run tauri build
```

## Danksagung

Inspiriert von [CodexBar](https://github.com/steipete/CodexBar), insbesondere von der Idee, jedes KI-Coding-Limit sichtbar zu halten, ohne ein Dashboard öffnen zu müssen. BirdNion pflegt seine eigene plattformübergreifende Lösung für Anbieter, Konfiguration und Distribution.

## Lizenz

MIT.
