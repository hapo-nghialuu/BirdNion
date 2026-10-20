<div align="center">
  <img src="docs/social.png" alt="BirdNion - AI quota companion for macOS and Linux" />
</div>

# BirdNion - Pour que vos agents IA respectent votre budget.

> Tous vos quotas de codage IA et réglages d’agents, dans la barre des menus macOS ou la zone de notification Linux.

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · **Français**


[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-fcc624?style=flat-square&logo=linux&logoColor=111)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

38 fournisseurs. BirdNion est une petite application pour la barre des menus de macOS 14+ et la zone de notification Linux. Elle garde vos limites de codage IA à portée de vue, indique quand chaque période se réinitialise et centralise les sources de données de chaque agent de codage. Codex, Claude, MiniMax, OpenRouter, DeepSeek, z.ai, ElevenLabs, Deepgram, Groq, Grok, xAI, OpenAI, Ollama, GitHub Copilot, Kilo, Command Code, Xiaomi MiMo, Alibaba/Qwen, Cursor, Gemini, Kiro, OpenCode, OpenCode Go, Antigravity, AWS Bedrock, FreeModel, Devin et Hapo AI Hub — ainsi que des fournisseurs intégrés par des extensions JavaScript (Aixy, Atlas Cloud, ClinePass, LiteLLM, Muse Code, Nous Portal, Raycast, Sakana AI, Venice, xKiro).

L’application native macOS utilise SwiftUI/AppKit et un sous-ensemble allégé de `CodexBarCore`, intégré au dépôt. Le portage Linux se trouve dans `linux/` et utilise Tauri v2 avec un cœur Rust et une interface en TypeScript sans framework. Les deux plateformes partagent le même schéma XDG de configuration des fournisseurs.

## Pourquoi

- **Planifiez selon les réinitialisations.** Pour chaque fournisseur, des périodes de 5 heures, hebdomadaires, mensuelles, de crédits et de budget, avec des comptes à rebours de réinitialisation.
- **Suivez vos dépenses et vos coûts.** Analyse des fichiers JSONL locaux de Claude, statistiques de consommation hebdomadaires, classements de projets respectueux de la vie privée, graphiques de l’API d’administration Claude, crédits Codex, soldes OpenRouter, budgets Bedrock et synthèses des coûts ou crédits propres à chaque fournisseur, selon leur disponibilité.
- **Configurez les sources des agents.** Choisissez OAuth, CLI, cookies du navigateur, clés API, identifiants AWS, fichiers d’applications locaux ou applications des fournisseurs dans les réglages de chaque fournisseur.
- **Changez sans perdre le contexte.** macOS et Linux permettent de basculer entre des profils Claude/Codex personnalisés, de réinitialiser les crédits et d’amorcer automatiquement Codex, ainsi que de gérer plusieurs comptes pour Codex, Copilot, Antigravity et FreeModel.
- **Gardez un bureau discret.** macOS peut faire défiler les pourcentages de quota des fournisseurs dans la barre des menus ; Linux fait défiler le logo et le pourcentage directement dans l’icône de la zone de notification.
- **La confidentialité d’abord.** BirdNion réutilise les sessions existantes et la configuration explicite. Il ne stocke aucun mot de passe et n’effectue aucune analyse illimitée du disque.

## Installation

### Prérequis

- macOS 14+ (Sonoma)
- Linux x86_64 pour les paquets `.deb`, `.rpm` et `.AppImage` publiés

### Versions GitHub

Téléchargez les paquets précompilés depuis les [versions GitHub](https://github.com/hapo-nghialuu/BirdNion/releases) :

- `BirdNion-<version>.zip` - application macOS universelle, signée avec Developer ID et notariée par Apple.
- `BirdNion_<version>_amd64.deb` - paquet Ubuntu/Debian.
- `BirdNion-<version>-1.x86_64.rpm` - paquet Fedora/RHEL.
- `BirdNion_<version>_amd64.AppImage` - paquet Linux portable.
- Le cask Homebrew utilise SHA256.
- Le ticket de notarisation est joint à l’application : Gatekeeper l’ouvre donc directement, même hors ligne, après la confirmation habituelle « téléchargée depuis Internet ».

### macOS via Homebrew

Commande d’installation recommandée :

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

La commande complète sélectionne explicitement `hapo-nghialuu/tap/birdnion` : aucune étape `brew tap` distincte n’est nécessaire.

Installation avec le nom court après l’ajout du tap :

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

Ou accordez votre confiance à l’ensemble du tap :

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

N’utilisez pas `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` comme méthode d’installation habituelle. C’est une dérogation d’environnement côté utilisateur ; elle ne peut pas être placée dans `Casks/birdnion.rb` pour contourner la vérification de confiance avant que Homebrew ne charge le cask.

### Mise à jour sur macOS

```bash
brew update && brew upgrade --cask birdnion
```

Exécutez d’abord `brew update` (enchaîné avec `&&`) pour que le tap récupère le dernier cask —
`brew upgrade` seul n’actualise pas un tap tiers et indiquera
« déjà installé » en se basant sur l’ancienne version.

Vérifiez la version installée :

```bash
brew list --cask --versions birdnion   # or: brew info --cask birdnion
```

### Linux

Téléchargez l’un des fichiers Linux de [la dernière version](https://github.com/hapo-nghialuu/BirdNion/releases/latest) :

```bash
sudo apt install ./BirdNion_<version>_amd64.deb
# or
sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# or
chmod +x BirdNion_<version>_amd64.AppImage
./BirdNion_<version>_amd64.AppImage
```

### Premier lancement

- Ouvrez BirdNion depuis la barre des menus macOS ou la zone de notification Linux.
- Ouvrez Réglages -> Fournisseurs et activez ceux que vous utilisez.
- Installez les sources dont vous avez besoin ou connectez-vous à celles-ci : CLI, sessions du navigateur, OAuth/autorisation par appareil, clés API, fichiers d’applications locaux ou identifiants cloud selon le fournisseur.
- Facultatif : définissez les libellés des comptes, la visibilité dans la barre des menus, les intervalles d’actualisation, la source des cookies, la région, le mode d’authentification AWS, le périmètre d’organisation Kilo, l’hôte d’entreprise Copilot ou la métrique à afficher dans la barre des menus pour chaque fournisseur.

## Configuration des réglages des agents

BirdNion a vocation à devenir une console légère de réglages et de configuration pour les agents de codage IA, et pas seulement un outil de suivi des quotas.

Fonctionnalités actuelles :

- Activation et ordre des fournisseurs, libellés des comptes, intervalles d’actualisation et visibilité dans la barre des menus.
- Sélecteurs de sources pour les fournisseurs pouvant lire OAuth, CLI, cookies du navigateur, API d’administration ou état local d’une application.
- Réglages propres aux fournisseurs : mode des cookies, en-têtes de cookies saisis manuellement, régions MiniMax/z.ai/Alibaba, clés/profil/région AWS, identifiant de projet Deepgram, périmètre d’organisation Kilo, hôte d’entreprise Copilot et choix de la métrique affichée dans la barre des menus.
- Détection des sessions locales des agents qui gèrent leur propre état d’authentification : Claude Code, Codex CLI, Gemini CLI, Kiro, Cursor, Antigravity et outils similaires.
- Console de configuration Claude Code : backends prédéfinis ou personnalisés, niveaux de modèles, portée globale ou par projet, import JSON et suppression sûre des clés d’environnement gérées par BirdNion.
- Basculement entre profils Claude Code et Codex personnalisés, avec vérification réelle de leur disponibilité, de leur validité et de l’état du proxy, et activation bloquée en cas de doute.
- Détection de plusieurs comptes et basculement entre eux pour Codex, GitHub Copilot, Antigravity et FreeModel, y compris les sessions FreeModel par navigateur.

Orientations prévues :

- Étendre la gestion des profils à d’autres agents de codage que Claude Code.
- Afficher un état plus détaillé des connexions et des sources de chaque agent.
- Valider les chemins de configuration locaux et la disponibilité des CLI.
- Fournir des conseils de mise en route pour Claude Code, Codex CLI, Gemini CLI, Kiro et les futurs agents.
- Conserver les préférences de BirdNion dans la couche de configuration de BirdNion sans toucher au stockage des identifiants de chaque agent.

## Fournisseurs

- **Codex** - API OAuth à partir de `~/.codex/auth.json`, recours à une clé API ou au service local `codex app-server` en cas d’échec, état du service, version, crédits, crédits de réinitialisation, données web OpenAI supplémentaires facultatives et gestion du basculement entre comptes.
- **Claude** - API OAuth, cookies du navigateur, CLI ou API d’administration ; périodes de 5 heures/hebdomadaires/Opus/Sonnet, routines quotidiennes, analyse des coûts locaux, données web supplémentaires (dépenses hors forfait et crédits prépayés restants) et graphique d’administration sur 30 jours. Les forfaits Max affichent leur multiplicateur d’utilisation (Max 5x / Max 20x).
- **MiniMax** - Jeton API, jeton d’environnement ou cookies de secours pour la consommation du forfait de codage, le nom du forfait, les points/l’abonnement et la région globale/CN.
- **OpenRouter** - Jeton API pour les crédits prépayés et, en option, une limite de dépense par clé.
- **DeepSeek** - Jeton API pour le solde USD/CNY, avec distinction entre crédits payés et offerts et alerte de solde faible.
- **z.ai** - Jeton API avec région globale/CN pour les limites de quota et le calcul du pourcentage restant.
- **ElevenLabs** - Clé API pour les crédits de caractères, les emplacements de voix, les voix professionnelles, le forfait et l’état de l’abonnement.
- **Deepgram** - Clé API avec identifiant de projet facultatif pour les synthèses de consommation et un mode agrégeant tous les projets.
- **Groq** - Clé API pour les métriques de requêtes, de jetons et de succès du cache fournies par Prometheus.
- **Grok** - Sans configuration à partir de `~/.grok/auth.json` (`grok login`) ; RPC CLI `x.ai/billing`, puis gRPC-web de facturation grok.com via les cookies Chrome / un jeton d’authentification Bearer ; identité SuperGrok et périodes de crédits. Coûts locaux dans l’onglet Tout à partir de `~/.grok/sessions/**/signals.json` (totaux de jetons × grille de prix pondérés des modèles).
- **xAI** - Clé API de gestion et identifiant d’équipe pour la plateforme développeur, distincte de l’abonnement grand public Grok ; solde prépayé et dépenses sur la plateforme sur 30 jours.
- **OpenAI** - API d’administration de la plateforme (`OPENAI_ADMIN_KEY` / configuration) pour les dépenses d’organisation aujourd’hui/sur 7 j/sur 30 j ; identifiant de projet facultatif ; repli sur l’ancien système d’attribution de crédits pour les clés API utilisateur. Ne concerne pas l’abonnement ChatGPT/Codex (utilisez Codex pour cela).
- **Ollama** - Consommation Cloud par session/par semaine via les cookies ollama.com (Automatique/Manuel) ; `OLLAMA_API_KEY` vérifie en option l’accès à l’API Cloud.
- **GitHub Copilot** - Autorisation GitHub par appareil ou PAT de secours, hôte d’entreprise, gestion complète des comptes (ajout/basculement/suppression), consommation premium, nom d’utilisateur et données budgétaires supplémentaires via les cookies web.
- **Kilo** - Jeton API ou session CLI, périmètre d’organisation Kilo, crédits et détails de recharge automatique.
- **Kiro** - Consommation via CLI, crédits/dépassements et 9 modes d’affichage dans la barre des menus.
- **Command Code** - Cookies du navigateur ou saisis manuellement pour les crédits de facturation et le catalogue des forfaits.
- **Xiaomi MiMo** - Cookies du navigateur pour le solde, les détails du forfait de jetons et la consommation.
- **Alibaba/Qwen** - Cookies du navigateur et région internationale/CN pour les périodes des forfaits de codage et de jetons.
- **Cursor** - `state.vscdb` de Cursor en priorité, cookies du navigateur en secours, synthèse de consommation, identité et consommation des requêtes.
- **Gemini** - Identifiants OAuth de Gemini CLI à partir de `~/.gemini/oauth_creds.json` pour les niveaux de quota Cloud Code Assist.
- **OpenCode** - Cookies du navigateur pour la consommation glissante/hebdomadaire et le renouvellement de l’abonnement.
- **OpenCode Go** - Cookies du navigateur et page de l’espace de travail Go pour la consommation glissante/hebdomadaire/mensuelle et le solde Zen.
- **Antigravity** - Détection du processus local/par CLI et stockage des comptes Google OAuth pour les catégories de quotas et les données associées à chaque compte.
- **AWS Bedrock** - Clés d’accès AWS ou profil nommé, région, champs budgétaires et consommation CloudWatch/Cost.
- **FreeModel** - Sessions du navigateur de `freemodel.dev` pour les budgets en dollars sur 5 heures et par semaine, avec basculement de compte par navigateur et prise en charge des cookies gérés.
- **Devin** - Quotas quotidiens et hebdomadaires à partir de `app.devin.ai/api/<org>/billing/quota/usage`. Importe automatiquement le jeton de session du navigateur et l’organisation depuis le localStorage de Chrome, ou accepte un jeton Bearer saisi manuellement avec une organisation facultative (slug ou identifiant interne `org-...`).

D’autres fournisseurs sont les bienvenus s’ils s’intègrent au modèle `QuotaProvider` existant.

## Mascotte, icône et captures d’écran

Sur macOS, l’icône de la barre des menus est l’oiseau BirdNion par défaut. Lorsque l’option « Afficher le pourcentage dans la barre des menus » est activée, la barre fait défiler les pourcentages de quota des fournisseurs actifs avec leur logo. Linux affiche le logo et le pourcentage du fournisseur en rotation directement dans l’icône de la zone de notification.

<div align="center">
  <img src="website/assets/birdnion-readme-bird-quota-384.png" width="196" alt="BirdNion mascot holding a blue and yellow quota bar" />
  <br />
  <strong>BirdNion, votre compagnon pour les quotas</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/logo.png" width="112" alt="BirdNion app icon" />
  <br />
  <strong>Icône de l’application BirdNion</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/usage-overview.png" width="426" alt="BirdNion usage and cost overview" />
  <br />
  <strong>Vue d’ensemble de la consommation et des coûts</strong>
</div>

<br />

<div align="center">
  <img src="website/assets/control-surface-redraw.jpg" width="776" alt="Illustrated BirdNion Linux control surface based on the current Settings implementation" />
  <br />
  <strong>Panneau de commande · illustration basée sur les réglages Linux actuels</strong>
</div>

## Fonctionnalités

- Affichage facultatif des valeurs des fournisseurs en rotation dans la barre des menus macOS ou l’icône de la zone de notification Linux, avec activation par fournisseur et commandes de réorganisation adaptées à chaque plateforme.
- Jauges de consommation propres à chaque fournisseur avec comptes à rebours de réinitialisation.
- La configuration guidée renvoie les erreurs corrigeables d’un fournisseur vers le réglage précis, enregistre d’abord les modifications, puis n’indique le fournisseur comme actif qu’après la réussite d’un véritable autotest.
- Un badge compact du centre d’actions dans l’en-tête de la fenêtre contextuelle ouvre les réglages pour les problèmes actuels de configuration ou de connexion ; les éléments résolus disparaissent automatiquement, sans conservation d’un historique des problèmes.
- Actualisation progressive : chaque fournisseur publie ses données dès que leur récupération est terminée.
- Les dernières données connues restent visibles pendant les actualisations.
- Sélecteurs de sources par fournisseur : OAuth, CLI, cookies web, API d’administration, état local d’une application et clés statiques.
- Intervalles d’actualisation et visibilité dans la barre des menus propres à chaque fournisseur.
- Sélecteur de source des cookies avec modes Automatique, Manuel et Désactivé pour les fournisseurs utilisant des cookies.
- Graphiques des coûts locaux pour 17 sources d’agents — Claude, Codex, Grok, Kiro, Oh My Pi, Pi, Devin, OpenCode, Gemini CLI, Copilot CLI, Antigravity, Cursor, Amp, Droid, Kimi, Qwen Code et Goose — avec un historique persistant conservant les valeurs maximales. Les barres enregistrées alimentent immédiatement l’interface, tandis qu’une analyse en direct plus ciblée actualise les jours récents.
- Un résumé compact des statistiques dans l’onglet Tout ouvre Réglages -> Statistiques pour comparer les 7 derniers jours et consulter les classements de projets sur 7/30/90 jours. Claude, Codex et Grok déduisent des identifiants de projet respectueux de la vie privée à partir des métadonnées de leurs sessions locales ; seule la consommation résiduelle non attribuable reste explicitement marquée `Unknown`.
- Graphique de l’API d’administration Claude sur 30 jours et données supplémentaires du tableau de bord web Codex lorsque ces options sont activées.
- Valeurs d’affichage personnalisées pour Kiro : crédits restants, pourcentage, consommé/total et modes de dépassement.
- Notifications de quota et de défaillance des fournisseurs avec seuils configurables.
- Fichier de configuration XDG avec permissions restrictives.

## Configuration et stockage

| Données | Emplacement |
|---|---|
| Liste des fournisseurs, indicateurs d’activation, clés API, région, budget, identifiant de projet, URL de base, libellé du compte | `~/.config/birdnion/settings.json` |
| Chemin de configuration prioritaire | `$BIRDNION_CONFIG` |
| Chemin XDG prioritaire | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| Ancienne configuration | `~/.birdnion/settings.json` |
| OAuth Codex | `~/.codex/auth.json`, géré par Codex CLI |
| OAuth Claude | Élément macOS Keychain `Claude Code-credentials` ; Linux `~/.claude/.credentials.json` ; tous deux gérés par Claude Code/CLI |
| OAuth Gemini | `~/.gemini/oauth_creds.json` |
| Session Cursor | macOS : `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` ; Linux : `~/.config/Cursor/User/globalStorage/state.vscdb` |
| Comptes OAuth Antigravity | `~/.config/birdnion/antigravity-oauth.json` |
| Comptes OAuth Copilot | `~/.config/birdnion/copilot-accounts.json` |
| Comptes gérés FreeModel | macOS : `~/Library/Application Support/BirdNion/freemodel-accounts.json` ; Linux : `~/.config/birdnion/freemodel-accounts.json` |
| Historique quotidien des coûts (onglet Tout) | `~/.config/birdnion/cost-history.json` (à côté des réglages ; fusion conservant les valeurs maximales pour préserver les anciennes barres même après suppression des sessions d’agents) |
| Historique des coûts par projet (Statistiques) | `~/.config/birdnion/project-cost-history.json` (stockage distinct facultatif ; clés de projet/identifiants de rétractation SHA-256, noms de dossiers assainis, fusion conservant les valeurs maximales dans les limites des agrégats, `0600`) |
| Préférences d’interface macOS | `UserDefaults` (`showPercentInMenuBar`, réglages de visibilité, d’actualisation, de source et d’affichage) |
| Préférences d’interface Linux | `localStorage` de la WebView Tauri ; les champs de cookies/visibilité/actualisation des fournisseurs restent dans `settings.json` |

Ordre de priorité des chemins de configuration :

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

Le fichier de configuration est écrit de manière atomique avec la permission `0600`.

## Note sur la confidentialité

BirdNion n’effectue aucune exploration illimitée du système de fichiers. Il ne lit les emplacements documentés que lorsque le fournisseur ou la source correspondant est activé : fichiers de configuration des fournisseurs, fichiers d’authentification CLI, stockages de cookies du navigateur, bases de données locales des IDE et journaux de session locaux des agents. Les jetons des fournisseurs sont conservés dans le fichier de configuration de BirdNion avec des permissions restrictives. Les fichiers de session OAuth, Keychain et CLI restent gérés par leurs outils d’origine.

Aucun mot de passe n’est stocké. Les cookies du navigateur ne sont réutilisés que si l’utilisateur choisit une source utilisant des cookies. Les statistiques ne conservent jamais le chemin complet d’un projet : Claude hache le jeton stable de son dossier de session, Codex hache un `cwd` absolu validé et Grok hache le jeton encodé de son dossier de session. Les chemins vérifiés ne peuvent servir qu’à améliorer le libellé assaini du nom de dossier ; l’interface et la synthèse copiée reçoivent ce libellé sûr ou une catégorie résiduelle explicite `Unknown`.

## Notes par plateforme

### Autorisations macOS

- **Accès complet au disque** - non requis pour les fonctions principales de l’application. Les fournisseurs utilisant des cookies du navigateur peuvent nécessiter des accès macOS supplémentaires selon le navigateur et son stockage de cookies.
- **Accès à Keychain** - OAuth Claude peut lire l’élément `Claude Code-credentials` géré par Claude Code/CLI ; l’import des cookies du navigateur peut aussi déclencher des demandes d’accès au trousseau Safe Storage du navigateur.
- **Demandes Fichiers et dossiers** - les vérifications des fournisseurs locaux peuvent déclencher des demandes macOS si la CLI ou l’utilitaire sous-jacent accède à des emplacements protégés.
- **Ce que BirdNion ne demande pas en arrière-plan** - aucune autorisation d’enregistrement de l’écran ni d’accessibilité.

### Linux

- Les fournisseurs utilisant des cookies du navigateur nécessitent un profil Chrome/Chromium/Brave/Edge/Firefox pris en charge et peuvent dépendre du trousseau de clés de l’environnement de bureau.
- La zone de notification affiche le logo et le pourcentage du fournisseur en rotation directement dans son icône, car les environnements de bureau Linux ne proposent pas de méthode portable pour afficher du texte à côté des icônes de notification.
- Les raccourcis globaux ne sont pas activés sur Linux ; utilisez la fenêtre de l’application et les commandes des réglages.

## Documentation

- [docs/build.md](docs/build.md) - compilation, signature et dépannage.
- [docs/system-architecture.md](docs/system-architecture.md) - architecture du système et historique des décisions.
- [docs/development-roadmap.md](docs/development-roadmap.md) - feuille de route historique.
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - audit de parité entre BirdNion et CodexBar.
- [docs/linux-parity-matrix.md](docs/linux-parity-matrix.md) - parité fonctionnelle macOS/Linux.
- [linux/README.md](linux/README.md) - développement Linux, création des paquets et notes sur la plateforme.

## Premiers pas (développement)

- Clonez le dépôt. Ouvrez `BirdNion.xcodeproj` pour macOS ou travaillez depuis `linux/` pour le développement Tauri.
- Lancez l’application une première fois, puis activez les fournisseurs dans Réglages -> Fournisseurs.
- Installez les sources dont vous avez besoin ou connectez-vous à celles-ci : CLI, cookies du navigateur, OAuth/autorisation par appareil, clés API, applications des fournisseurs ou fichiers de configuration locaux.
- Facultatif : configurez les cookies OpenAI pour les données supplémentaires du tableau de bord Codex et le routage des sources Claude pour OAuth/Web/CLI/API d’administration.

## Compilation à partir des sources

### macOS

Nécessite macOS 14+ et Xcode avec la prise en charge de Swift pour le schéma du projet.

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion intègre un paquet `CodexBarCore` allégé dans `Vendor/CodexBar` ; aucun clone externe dans `~/Desktop/CodexBar` n’est nécessaire.

### Linux

Le développement et les tests peuvent être effectués depuis `linux/` sur macOS ou Linux. Les paquets Linux natifs doivent être compilés sur Linux avec les dépendances WebKitGTK/AppIndicator installées.

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml

# On Linux: build .deb, .rpm, and AppImage bundles
npm run tauri build
```

## Remerciements

Inspiré de [CodexBar](https://github.com/steipete/CodexBar), notamment de l’idée de garder toutes les limites de codage IA visibles sans ouvrir un tableau de bord. BirdNion conserve ses propres intégrations de fournisseurs, sa configuration et sa distribution multiplateformes.

## Licence

MIT.
