# Cloudflare Analytics to InfluxDB v2

Ce script collecte les métriques Cloudflare via l’API GraphQL et les envoie dans un bucket InfluxDB v2. Il est conçu pour alimenter un tableau de bord Grafana (par exemple celui de Jorge de la Cruz) avec les données suivantes :

* Bande passante (bytes, cached\_bytes)
* Nombre de requêtes (requests, cached\_requests)
* Nombre de menaces (threats)
* Nombre de pages vues (pageviews)
* Nombre de visiteurs uniques (uniques)
* Répartition des requêtes par pays (country\_requests)

## Prérequis

1. **InfluxDB v2** installé et accessible (URL, port, organisation, bucket, token).
2. **Cloudflare** : un token API avec permissions en lecture sur l’API GraphQL pour la zone souhaitée.
3. **Outils** sur la machine où tourne le script :

   * `bash` (version 4+)
   * `curl` (pour requêtes HTTP)
   * `jq` (pour parser le JSON)
   * Accès réseau à `api.cloudflare.com` et à l’instance InfluxDB

## Installation

1. Clonez ou copiez le script dans un dossier, par exemple :

   ```bash
   mkdir -p ~/script/cloudflare
   cd ~/script/cloudflare
   # Copier cloudflare-analytics.sh ici
   chmod +x cloudflare-analytics.sh
   ```

2. Installez les dépendances si nécessaire :

   ```bash
   sudo apt update
   sudo apt install -y curl jq
   ```

## Configuration

Éditez les variables en début de script pour qu’elles correspondent à votre environnement :

```bash
# InfluxDB v2 Configuration
InfluxDBURL="http://XXX.XXX.XXX.XXX"       # URL ou IP de votre serveur InfluxDB
InfluxDBPort="8086"                       # Port InfluxDB (par défaut 8086)
InfluxDBBucket="cloudflare"                # Nom du bucket InfluxDB où écrire
InfluxDBOrg="ORGname"                     # Nom de l’organisation InfluxDB (sensible à la casse)
InfluxDBToken="token"                     # Token InfluxDB avec droits Write sur le bucket

# Cloudflare API credentials
cloudflareapikey="APItoken"              # Token API Cloudflare pour GraphQL
cloudflarezone="Zonetoken"               # Zone ID Cloudflare (<zoneTag>)
cloudflareemail="YourMail"               # Adresse e-mail associée au compte Cloudflare
```

* **InfluxDBToken** doit être un token avec **permissions Write** sur le bucket spécifié.
* **cloudflareapikey** doit avoir accès en lecture sur la zone GraphQL.
* **cloudflarezone** correspond à l’ID de la zone (zoneTag) dans Cloudflare.
* **cloudflareemail** est l’adresse liée au compte Cloudflare.

## Fonctionnement du script

1. Calcule la période : **dernier jour** (24 heures) en date UTC.
2. Construit la requête GraphQL pour extraire, pour chaque jour des 7 derniers jours :

   * Dimensions : `date`
   * Sommes : `bytes`, `cachedBytes`, `requests`, `cachedRequests`, `threats`, `pageViews` et la carte des pays (`countryMap.clientCountryName`, `countryMap.requests`)
   * Uniques : `uniques`
3. Envoi de la requête GraphQL à Cloudflare.
4. Pour chaque objet `httpRequests1dGroups` retourné :

   * Extrait la date (`date`) et convertit en timestamp UNIX (secondes).
   * Récupère les métriques : `cfBytes`, `cfCachedBytes`, `cfRequests`, `cfCachedRequests`, `cfThreats`, `cfPageViews`, `cfUniques`.
   * Construit une ligne InfluxDB en Line Protocol :

     ```
     cloudflare,zone=<zoneTag> bytes=<valeur>,cached_bytes=<valeur>,requests=<valeur>,cached_requests=<valeur>,threats=<valeur>,pageviews=<valeur>,uniques=<valeur> <timestamp>
     ```
   * Envoie cette ligne à InfluxDB (HTTP POST sur `/api/v2/write?bucket=<bucket>&org=<org>&precision=s`).
   * Parcourt ensuite la liste `countryMap` pour écrire, par pays :

     ```
     cloudflare,zone=<zoneTag>,country=<pays> country_requests=<valeur> <timestamp>
     ```
5. Après avoir traité tous les jours, envoie un point de test unique :

   ```
   cloudflare,zone=<zoneTag>,source=test debug=1 <timestamp>
   ```

   pour vérifier l’écriture dans InfluxDB.

## Exécution manuelle

Pour lancer manuellement :

```bash
cd ~/script/cloudflare
./cloudflare-analytics.sh
```

* Le script affichera chaque ligne InfluxDB (Line Protocol) envoyée, suivi du code HTTP 204 si réussi.
* En cas d’erreur Cloudflare (pas de données), le script terminera avec un message et code de sortie 1.

## Intégration avec systemd (optionnel)

Pour automatiser l’exécution toutes les 5 minutes :

1. Créez le service : `/etc/systemd/system/cloudflare-analytics.service`

   ```ini
   [Unit]
   Description=Cloudflare Analytics to InfluxDB
   After=network.target

   [Service]
   Type=oneshot
   User=<votre_utilisateur>
   WorkingDirectory=/home/<votre_utilisateur>/script/cloudflare
   ExecStart=/home/<votre_utilisateur>/script/cloudflare/cloudflare-analytics.sh
   ```

2. Créez le timer : `/etc/systemd/system/cloudflare-analytics.timer`

   ```ini
   [Unit]
   Description=Exécute cloudflare-analytics.service toutes les 5 minutes

   [Timer]
   OnBootSec=5min
   OnUnitActiveSec=5min
   AccuracySec=1s
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

3. Rechargez systemd et activez le timer :

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable cloudflare-analytics.timer
   sudo systemctl start cloudflare-analytics.timer
   ```

4. Vérifiez l’état du timer et des exécutions :

   ```bash
   systemctl list-timers cloudflare-analytics.timer
   journalctl -u cloudflare-analytics.service -f
   ```

## Vérification des données dans InfluxDB

1. Via la CLI Influx :

   ```bash
   influx query 'from(bucket: "cloudflare") |> range(start: -7d) |> limit(n: 10)' \
     --org ORGname \
     --host http://XXX.XXX.XXX.XXX:8086 \
     --token "token"
   ```

2. Via l’UI InfluxDB (Data Explorer) :

   * Sélectionnez le bucket `cloudflare`.
   * Choisissez la période (Last 7 days).
   * Sélectionnez la mesure `cloudflare` et les champs (bytes, requests, etc.).
   * Pour les stats par pays, utilisez le tag `country` et le champ `country_requests`.

## Dashboard Grafana

Importez le JSON du dashboard de Jorge de la Cruz (ou un dashboard personnalisé) :

* Datasource : InfluxDB v2 configurée avec URL `http://XXX.XXX.XXX.XXX:8086`, org `ORGname`, bucket `cloudflare`, token.
* Variable `zone` : valeur `Zonetoken`.
* Plage de temps : Last 7 days ou Last 24 hours pour inclure les points horaires.

## Support et personnalisation

* Pour étendre la période, modifiez la variable `back_seconds` (par exemple `7 * 24 * 3600` pour 7 jours d’un coup).
* Pour ajouter d’autres champs Cloudflare (navigateur, statut HTTP, etc.), modifiez la requête GraphQL et ajoutez-les dans le payload Influx.
* Pour changer la fréquence d’exécution, ajustez `OnUnitActiveSec` dans le timer systemd.

---

*Ce README.md a été généré pour accompagner le script `cloudflare-analytics.sh` et faciliter son déploiement, son analyse et son intégration dans un système de monitoring InfluxDB + Grafana.*
