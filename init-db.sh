#!/bin/bash
set -e

# Ce script est exécuté par le conteneur PostgreSQL au premier démarrage.
# Il crée les trois bases de données nécessaires aux microservices.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    CREATE DATABASE db_auth;
    CREATE DATABASE db_stocks;
    CREATE DATABASE db_orders;

    GRANT ALL PRIVILEGES ON DATABASE db_auth TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE db_stocks TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE db_orders TO $POSTGRES_USER;
EOSQL

echo "Databases db_auth, db_stocks, db_orders created successfully."
