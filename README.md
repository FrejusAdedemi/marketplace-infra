# marketplace-infra

**Auteur :** Laura  
**Rôle dans le projet :** Infrastructure & API Gateway

Ce repo contient toute l'infrastructure Docker de la plateforme Marketplace : orchestration des services, configuration des bases de données, gestion des réseaux et des secrets. Il est le point de départ pour lancer l'ensemble de la plateforme en local ou en production.

---

## Table des matières

1. [Ce que j'ai fait et pourquoi](#ce-que-jai-fait-et-pourquoi)
2. [Architecture](#architecture)
3. [Choix techniques](#choix-techniques)
4. [Structure de clonage attendue](#structure-de-clonage-attendue)
5. [Installation et lancement](#installation-et-lancement)
6. [Commandes utiles](#commandes-utiles)
7. [Vérification du bon fonctionnement](#vérification-du-bon-fonctionnement)
8. [Détail des fichiers](#détail-des-fichiers)
9. [Sécurité réseau](#sécurité-réseau)
10. [Variables d'environnement](#variables-denvironnement)

---

## Ce que j'ai fait et pourquoi

### `docker-compose.yml`

J'ai créé un fichier `docker-compose.yml` unique qui orchestre les 10 services de la plateforme (3 bases de données, 5 microservices, 1 gateway, 1 frontend).

**Pourquoi un seul fichier dans un repo dédié ?**  
Chaque microservice appartient à un repo différent (un par membre de l'équipe). Le `docker-compose.yml` doit donc être dans un repo neutre qui appartient à l'infrastructure, pas à un service en particulier. Cela permet à n'importe qui de cloner ce repo et de lancer toute la plateforme sans modifier les repos des autres.

**Pourquoi des `build: context:` et pas des images pré-buildées ?**  
En phase de développement, chaque membre modifie son service en continu. Utiliser `build: context: ../nom-du-service` permet à Docker de recompiler l'image directement depuis le code source local à chaque `docker compose up --build`. C'est plus rapide que de push/pull des images sur un registry à chaque changement.

**Pourquoi `condition: service_healthy` dans les `depends_on` ?**  
Un simple `depends_on` ne garantit que le démarrage du conteneur, pas que le service à l'intérieur est prêt à répondre. PostgreSQL, par exemple, démarre son processus avant d'accepter des connexions. Sans `condition: service_healthy`, l'auth-service tenterait de se connecter à la BDD trop tôt et crasherait. Les `healthcheck` permettent de synchroniser le démarrage dans le bon ordre.

**Pourquoi `restart: unless-stopped` ?**  
En développement, si un service crash (bug, BDD pas encore prête), on veut qu'il redémarre automatiquement plutôt que de devoir relancer manuellement. `unless-stopped` redémarre automatiquement sauf si on a explicitement arrêté le conteneur avec `docker compose stop`.

### `init-db.sh`

J'ai créé un script shell monté dans `/docker-entrypoint-initdb.d/` du conteneur PostgreSQL.

**Pourquoi ce mécanisme ?**  
L'image officielle PostgreSQL exécute automatiquement tous les scripts `.sh` et `.sql` présents dans `/docker-entrypoint-initdb.d/` lors du **premier démarrage** (quand le volume est vide). C'est le mécanisme officiel recommandé pour initialiser une base PostgreSQL dans Docker, sans avoir à modifier l'image de base ni créer une image custom.

**Pourquoi un seul PostgreSQL pour trois bases ?**  
Le projet impose une isolation des données par service (chaque service possède sa propre base). Cependant, faire tourner trois instances PostgreSQL séparées consommerait trois fois plus de mémoire et de CPU pour un gain minimal en développement. Un seul serveur PostgreSQL avec trois bases (`db_auth`, `db_stocks`, `db_orders`) offre la même isolation logique des données tout en restant léger. En production, on pourrait envisager des instances séparées.

**Pourquoi `set -e` au début du script ?**  
Cette option fait échouer le script immédiatement si une commande retourne une erreur. Sans elle, le script pourrait continuer même si la création d'une base a échoué, ce qui produirait des erreurs silencieuses difficiles à diagnostiquer.

### `.env.example`

J'ai listé toutes les variables d'environnement nécessaires à l'ensemble de la plateforme dans un seul fichier.

**Pourquoi un `.env.example` global et pas un par service ?**  
Chaque service a son propre `.env.example` dans son repo pour son usage autonome. Le `.env.example` global ici sert à lancer toute la plateforme d'un coup via le `docker-compose.yml`. Il regroupe toutes les variables au même endroit pour que quelqu'un qui clone ce repo sache exactement quoi configurer.

**Pourquoi des valeurs génériques (`change_me_...`) et pas de vraies valeurs par défaut ?**  
Des valeurs par défaut réalistes (ex: `password123`) sont souvent copiées telles quelles en production par inadvertance. Des valeurs explicitement fausses (`change_me_postgres_password`) forcent le développeur à les remplacer consciemment. C'est une bonne pratique de sécurité.

**Pourquoi ne pas committer le `.env` ?**  
Le fichier `.env` contient les vraies valeurs des secrets (mots de passe, clés JWT, etc.). Le committer dans Git exposerait ces secrets dans l'historique Git, même si on le supprime dans un commit ultérieur. Le `.gitignore` l'exclut systématiquement.

### `.gitignore`

Exclut le fichier `.env` (secrets) et les fichiers de logs.

### `README.md`

Ce fichier. Documente l'ensemble des choix, de l'architecture, et des procédures.

---

## Architecture

```
Internet
   │
   ▼ (port 8080)
┌─────────────────────────────────────────┐
│  gateway  ←── réseau PUBLIC             │
│  (seul service avec ports: exposés)     │
└────────────────┬────────────────────────┘
                 │ réseau INTERNAL
    ┌────────────┼─────────────────────┐
    │            │                     │
    ▼            ▼                     ▼
auth-service  product-service    stock-service
:3001          :3002               :3003
(db_auth)     (MongoDB)           (db_stocks)
    │
    ▼
order-service          pepper-service
:3004                  :3005
(db_orders)            (expose: seulement)
    │
    ▼
  ┌───────────────────────────────┐
  │  postgres  │  mongodb  │ redis │
  └───────────────────────────────┘
```

Le frontend (port 4200) est sur le réseau PUBLIC et ne communique qu'avec le gateway.  
Aucun microservice n'est accessible depuis l'extérieur, uniquement via le gateway.

---

## Choix techniques

### Versions des images Docker

| Image | Version choisie | Raison |
|-------|----------------|--------|
| `postgres` | `16-alpine` | Version LTS stable, image Alpine = image minimale (~50 Mo vs ~400 Mo pour debian), réduction de la surface d'attaque |
| `mongo` | `7` | Version imposée par le document de spécification du projet. L'image mongo:7 (Debian Bookworm) inclut mongosh nativement, requis pour le healthcheck. |
| `redis` | `7-alpine` | Version LTS, Alpine pour la légèreté |

### Deux réseaux Docker séparés

Deux réseaux ont été définis : `public` et `internal`.

- Le réseau `internal` a le flag `internal: true` : cela signifie que les conteneurs sur ce réseau **n'ont aucun accès à internet**. Un microservice compromis ne peut pas exfiltrer de données vers l'extérieur.
- Seul le gateway est sur les deux réseaux, jouant le rôle de frontière entre l'extérieur et l'intérieur.
- Le `pepper-service` utilise `expose:` (et non `ports:`) : le port est accessible depuis le réseau interne Docker, mais **jamais mappé sur la machine hôte**. Même sur la machine de développement, il est impossible d'appeler le pepper-service directement depuis un navigateur ou Postman.

### Volumes nommés

Les volumes (`postgres_data`, `mongo_data`, `redis_data`) sont nommés explicitement.

**Pourquoi des noms explicites ?**  
Docker génère des noms aléatoires pour les volumes anonymes, ce qui rend leur identification difficile (`docker volume ls` retourne des hashes incompréhensibles). Des noms explicites (`marketplace-postgres-data`) permettent de les retrouver et les inspecter facilement.

### Healthchecks avec `wget` plutôt que `curl`

Les images Alpine n'incluent pas `curl` par défaut, mais incluent `wget`. Les healthchecks utilisent donc `wget -qO-` (silencieux, output vers stdout) pour éviter d'avoir à installer `curl` dans chaque image.

---

## Structure de clonage attendue

Le `docker-compose.yml` référence les autres repos via des chemins relatifs (`../nom-du-repo`). Tous les repos doivent être clonés **côte à côte** dans le même dossier parent :

```
parent/
├── marketplace-infra/            ← ce repo (docker-compose.yml ici)
├── marketplace-gateway-service/  ← repo de Laura
├── marketplace-auth-service/     ← repo de Frejus
├── marketplace-product-service/  ← repo d'Etienne
├── marketplace-stock-service/    ← repo de Karl
├── marketplace-order-service/    ← repo de Karl
├── marketplace-pepper-service/   ← repo de Frejus
└── marketplace-frontend/         ← repo commun (base créée par Frejus)
```

Si un repo n'est pas encore disponible (service pas encore développé), commenter temporairement le service correspondant dans le `docker-compose.yml` pour pouvoir lancer le reste.

---

## Installation et lancement

### 1. Cloner tous les repos

```bash
git clone <url-marketplace-infra>
git clone <url-marketplace-gateway-service>
git clone <url-marketplace-auth-service>
git clone <url-marketplace-product-service>
git clone <url-marketplace-stock-service>
git clone <url-marketplace-order-service>
git clone <url-marketplace-pepper-service>
git clone <url-marketplace-frontend>
```

### 2. Configurer les variables d'environnement

```bash
cd marketplace-infra
cp .env.example .env
# Ouvrir .env et remplacer toutes les valeurs "change_me_..."
```

### 3. Lancer la plateforme

```bash
docker compose up --build
```

Pour lancer en arrière-plan :

```bash
docker compose up --build -d
```

> **Premier lancement :** PostgreSQL exécute `init-db.sh` automatiquement et crée les trois bases de données. Ce script ne s'exécute qu'une seule fois (quand le volume `postgres_data` est vide).

---

## Commandes utiles

```bash
# Voir les logs de tous les services en temps réel
docker compose logs -f

# Voir les logs d'un service spécifique
docker compose logs -f gateway
docker compose logs -f auth-service

# Arrêter tous les services (conserve les volumes/données)
docker compose down

# Arrêter et supprimer les volumes — RESET COMPLET des BDD
docker compose down -v

# Rebuild et relancer un seul service après modification du code
docker compose up --build gateway

# Vérifier l'état des conteneurs (running, healthy, etc.)
docker compose ps

# Accéder au shell d'un conteneur
docker compose exec postgres psql -U marketplace_user -d db_auth
docker compose exec redis redis-cli
```

---

## Vérification du bon fonctionnement

Une fois lancé, le gateway expose un endpoint `/health` qui agrège l'état de tous les services :

```bash
curl http://localhost:8080/health
```

Réponse attendue :

```json
{
  "status": "ok",
  "services": {
    "auth-service": "ok",
    "product-service": "ok",
    "stock-service": "ok",
    "order-service": "ok",
    "pepper-service": "ok"
  }
}
```

Si un service est down, son statut sera `"degraded"` ou `"unreachable"` et le status global sera `"degraded"`.

Le frontend est accessible sur [http://localhost:4200](http://localhost:4200).  
L'API est accessible sur [http://localhost:8080](http://localhost:8080).

---

## Détail des fichiers

### `docker-compose.yml`

Orchestre les 10 services. Points clés :
- `depends_on` avec `condition: service_healthy` → ordre de démarrage garanti
- `restart: unless-stopped` → redémarrage automatique en cas de crash
- `expose:` pour pepper-service → accessible en interne seulement, jamais depuis l'hôte
- `ports:` uniquement sur gateway (8080) et frontend (4200)

### `init-db.sh`

Exécuté par PostgreSQL au premier démarrage. Crée les trois bases de données et accorde tous les droits à l'utilisateur configuré.

```
db_auth   → auth-service (utilisateurs, tokens)
db_stocks → stock-service (stocks par magasin)
db_orders → order-service (commandes et lignes de commande)
```

### `.env.example`

Template de configuration. Toutes les valeurs `change_me_...` doivent être remplacées dans le `.env` local. Ne jamais committer `.env`.

### `.gitignore`

Exclut `.env` et les fichiers de logs (`*.log`).

---

## Sécurité réseau

| Service         | Réseau public | Réseau internal | Ports hôte |
|-----------------|:-------------:|:---------------:|:----------:|
| gateway         | ✅            | ✅              | 8080       |
| frontend        | ✅            | ❌              | 4200       |
| auth-service    | ❌            | ✅              | aucun      |
| product-service | ❌            | ✅              | aucun      |
| stock-service   | ❌            | ✅              | aucun      |
| order-service   | ❌            | ✅              | aucun      |
| pepper-service  | ❌            | ✅ (`expose:`)  | aucun      |
| postgres        | ❌            | ✅              | aucun      |
| mongodb         | ❌            | ✅              | aucun      |
| redis           | ❌            | ✅              | aucun      |

Le réseau `internal` a le flag Docker `internal: true` : les conteneurs sur ce réseau n'ont **aucun accès à internet**, même entre eux vers l'extérieur.

---

## Variables d'environnement

| Variable | Usage | Valeur exemple |
|----------|-------|----------------|
| `POSTGRES_USER` | Utilisateur PostgreSQL commun à toutes les BDD | `marketplace_user` |
| `POSTGRES_PASSWORD` | Mot de passe PostgreSQL | *(secret)* |
| `MONGO_INITDB_ROOT_USERNAME` | Utilisateur admin MongoDB | `marketplace_user` |
| `MONGO_INITDB_ROOT_PASSWORD` | Mot de passe MongoDB | *(secret)* |
| `REDIS_HOST` / `REDIS_PORT` | Coordonnées Redis (pour le gateway) | `redis` / `6379` |
| `JWT_SECRET` | Clé de signature des access tokens (min. 32 chars) | *(secret)* |
| `JWT_EXPIRES_IN` | Durée de vie des access tokens | `1h` |
| `JWT_REFRESH_SECRET` | Clé de signature des refresh tokens | *(secret)* |
| `JWT_REFRESH_EXPIRES_IN` | Durée de vie des refresh tokens | `7d` |
| `INTERNAL_SECRET` | Secret partagé entre gateway et pepper-service | *(secret)* |
| `GATEWAY_PORT` | Port exposé du gateway sur la machine hôte | `8080` |

Voir `.env.example` pour la liste complète.
