#!/usr/bin/env bash
# ============================================================================
# Orchestrateur maître du pipeline Paris Budget Dashboard.
#
# Enchaîne les 4 phases dans l'ordre :
#   1. sync     — récupère les sources (OpenData API → BQ ou JSON direct)
#   2. dbt      — transforme les tables raw en marts (dbt run)
#   3. export   — exporte BQ → JSONs consommés par le front
#   4. enrich   — enrichit les JSONs (Sirene, LLM grounded, thématique, etc.)
#
# Chaque phase est idempotente : les scripts réutilisent leurs caches
# (sirene_companies.json, beneficiaire_grounded.json, …) donc un re-run
# sans nouvelle donnée = quasi no-op.
#
# Usage :
#   bash pipeline/run_all.sh                    # tout faire
#   bash pipeline/run_all.sh --skip=sync,dbt    # juste export + enrich
#   bash pipeline/run_all.sh --only=enrich      # juste l'enrichissement
#   bash pipeline/run_all.sh --tier1            # active enrich tier1 (LLM payant)
#   bash pipeline/run_all.sh --cron-safe        # skip enrich LLM, garde tier2 Sirene
#   bash pipeline/run_all.sh --dry-run          # imprime ce qui serait fait
#   bash pipeline/run_all.sh --strict           # CI auto-refresh : tout échec
#                                               # arrête tout, dbt test obligatoire
#
# Variables d'env reconnues :
#   ANTHROPIC_API_KEY     (requis pour enrich tier1 / grounded LLM)
#   GOOGLE_API_KEY        (optionnel, Gemini au lieu de Claude)
#   GOOGLE_APPLICATION_CREDENTIALS   (pour dbt + BQ)
#   SKIP_DBT=1            (équivalent --skip=dbt)
# ============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_DIR="$REPO_ROOT/pipeline"
PYTHON="${PYTHON:-python3}"

# --- Flags -------------------------------------------------------------------
PHASES=("sync" "dbt" "export" "enrich")
SKIP=""
ONLY=""
TIER1=false
CRON_SAFE=false
DRY_RUN=false
STRICT=false

for arg in "$@"; do
    case "$arg" in
        --skip=*)    SKIP="${arg#--skip=}" ;;
        --only=*)    ONLY="${arg#--only=}" ;;
        --tier1)     TIER1=true ;;
        --cron-safe) CRON_SAFE=true ;;
        --dry-run)   DRY_RUN=true ;;
        --strict)    STRICT=true ;;
        -h|--help)
            grep "^#" "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "⚠ arg inconnu : $arg"; exit 2 ;;
    esac
done

# SKIP_DBT=1 compat ancien usage
if [[ "${SKIP_DBT:-0}" == "1" && "$SKIP" != *"dbt"* ]]; then
    SKIP="${SKIP:+$SKIP,}dbt"
fi

should_run() {
    local phase="$1"
    if [[ -n "$ONLY" ]]; then
        [[ ",$ONLY," == *",$phase,"* ]] && return 0 || return 1
    fi
    [[ ",$SKIP," == *",$phase,"* ]] && return 1 || return 0
}

run_step() {
    local label="$1"; shift
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "▶ $label"
    echo "  $ $*"
    echo "────────────────────────────────────────────────────────"
    if $DRY_RUN; then
        echo "  (dry-run, skipping)"
        return 0
    fi
    "$@"
}

# Échec d'une étape. En interactif on prévient et on continue : l'utilisateur
# lit le ⚠ et décide. En --strict (auto-refresh CI) on s'arrête : un sync raté
# laisse `raw` périmé, un export raté laisse des JSON à moitié réécrits, et
# « on continue » finit par publier ça sur le site sans que personne ne lise
# le ⚠.
soft_fail() {
    local msg="$1"
    if $STRICT; then
        echo "  ✗ $msg — arrêt (--strict)"
        exit 1
    fi
    echo "  ⚠ $msg — on continue"
}

cd "$REPO_ROOT"

# --- 1. SYNC ----------------------------------------------------------------
if should_run sync; then
    echo "════════════════════════════════════════════════════════"
    echo "═  1/4  SYNC — récupération des sources"
    echo "════════════════════════════════════════════════════════"
    # 7 datasets OpenData Paris → BQ raw.* (budget, AP, subv, assoc,
    # logements, voté, marchés). Stamps `_synced_at` pour dbt freshness.
    # Ingester générique ODS piloté par configs/cities/paris.yaml (parité
    # byte-identique prouvée vs l'ancien sync_opendata.py — voir
    # scripts/sync/verify_ods_parity.py).
    if [[ -f "$PIPELINE_DIR/scripts/sync/sync_city.py" ]]; then
        run_step "OpenData Paris core (7 datasets → BQ raw)" \
            $PYTHON "$PIPELINE_DIR/scripts/sync/sync_city.py" paris || \
            soft_fail "sync_city paris a échoué"
    fi
    # Chemin direct OpenData → JSON (ne dépend pas de BQ). Rapide, gratuit.
    run_step "Subventions JSON (OpenData Paris)" \
        $PYTHON "$PIPELINE_DIR/scripts/sync/fetch_subventions_opendata.py"
    # DECP marchés publics
    if [[ -f "$PIPELINE_DIR/scripts/sync/fetch_decp_paris.py" ]]; then
        run_step "Marchés publics DECP" \
            $PYTHON "$PIPELINE_DIR/scripts/sync/fetch_decp_paris.py" || \
            soft_fail "fetch_decp_paris a échoué"
    fi

    # Sources raw qui ne viennent PAS du portail ODS : reconstruites depuis des
    # fichiers versionnés du repo (extraits PDF, caches, scrapes) ou depuis un
    # autre portail. Absentes de cette phase jusqu'au 2026-08-25, elles avaient
    # disparu de `raw` sans que rien ne les recrée. b811 EN PREMIER : sans lui,
    # les subventions 2020 et 2021 (2,6 Md€) sortent SILENCIEUSEMENT de
    # core_subventions — c'est un UNION ALL, pas un JOIN, donc aucune erreur.
    #
    # Deux d'entre elles (deliberations, enrichment_caches) lisent pipeline/cache/,
    # ignoré par git : en CI leur source n'existe pas et elles doivent SKIP en
    # laissant raw intact. Le 2026-09-08, sync_deliberations a au contraire
    # WRITE_TRUNCATE trois tables prod avec 0 ligne (coquilles à une colonne,
    # staging cassé). Règle pour tout sync « depuis fichiers » : source absente
    # → skip explicite ; source présente mais vide → erreur ; jamais un
    # truncate à zéro.
    for s in sync_pdf_subventions_b811 sync_sirene_companies sync_enrichment_caches \
             sync_deliberations sync_pdf_investissements_localises sync_dette_garantie; do
        if [[ -f "$PIPELINE_DIR/scripts/sync/$s.py" ]]; then
            run_step "raw · $s" $PYTHON "$PIPELINE_DIR/scripts/sync/$s.py" || \
                soft_fail "$s a échoué"
        fi
    done

    # Marseille (data.gouv.fr) : budget primitif + compte administratif + subventions.
    if [[ -f "$PIPELINE_DIR/scripts/sync/sync_city.py" ]]; then
        run_step "Marseille (data.gouv.fr → BQ raw)" \
            $PYTHON "$PIPELINE_DIR/scripts/sync/sync_city.py" marseille || \
            soft_fail "sync_city marseille a échoué"
    fi
fi

# --- 2. DBT -----------------------------------------------------------------
if should_run dbt; then
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "═  2/4  DBT — transformations BigQuery"
    echo "════════════════════════════════════════════════════════"
    if command -v dbt >/dev/null 2>&1; then
        # En CI, on force le profil prod via DBT_PROFILES_DIR (sinon dbt
        # prend pipeline/profiles.yml et template DBT_USER → 'local').
        DBT_TARGET_FLAG=""
        if [[ -n "${DBT_PROFILES_DIR:-}" ]]; then
            DBT_TARGET_FLAG="--profiles-dir $DBT_PROFILES_DIR --target ${DBT_TARGET:-prod}"
        fi
        # dbt deps doit tourner avant run pour installer les packages (cf
        # pipeline/packages.yml). Idempotent.
        run_step "dbt deps" bash -c "cd '$PIPELINE_DIR' && dbt deps $DBT_TARGET_FLAG"
        # dbt seed : non fatal. Un CSV de seed cassé (les seeds nationaux ont
        # un bug de typage préexistant) ne doit PAS emporter tout le refresh
        # hebdo — c'est ce qui a fait poser DBT_SKIP_SEED=1, lequel a ensuite
        # empêché tout rechargement et laissé les seeds expirer en prod.
        # Les seeds valides sont chargés ; si un modèle dépend d'un seed
        # manquant, `dbt run` échouera juste après avec un message précis.
        if [[ "${DBT_SKIP_SEED:-0}" != "1" ]]; then
            run_step "dbt seed" bash -c "cd '$PIPELINE_DIR' && dbt seed $DBT_TARGET_FLAG" || \
                soft_fail "dbt seed a signalé des erreurs (dbt run dira si ça bloque)"
        else
            echo "  ⊘ dbt seed skipped (DBT_SKIP_SEED=1)"
        fi
        # Exclusions optionnelles via env var (utilisé en CI pour skip
        # marseille WIP qui n'a pas de source raw publiée).
        # Les communes de France ont leur propre tâche (run_national.sh) : leurs
        # modèles lisent ~10 Go par passage et un échec national ne doit jamais
        # bloquer la publication de Paris.
        # Canada and Brazil have their own prod workflows (dbt-ca-prod.yml, dbt-br-prod.yml): the Paris refresh
        # does not rebuild them. On 21 and 28/09 a Vancouver model hit BigQuery's CPU limit and, one error in
        # 382, stopped the Paris refresh twice — Paris data stayed at 14/09.
        DBT_EXCLUDE_FLAG="--exclude path:models/national path:models/ca path:models/br path:tests/ca path:tests/cat4_accounting_balance/assert_budget_national_reconciliation.sql ${DBT_RUN_EXCLUDE:-}"
        run_step "dbt run" bash -c "cd '$PIPELINE_DIR' && dbt run $DBT_TARGET_FLAG $DBT_EXCLUDE_FLAG"
        # Les tests dbt (unicité, réconciliation core ↔ staging, freshness,
        # valeurs acceptées…) ne tournent qu'en --strict : c'est le juge qui
        # décide si l'export a le droit de partir. `dbt run` PUIS `dbt test`
        # plutôt que `dbt build` : build saute l'aval d'un modèle dont un test
        # échoue et laisserait les marts prod mi-rebâtis, mi-anciens.
        if $STRICT; then
            run_step "dbt test (--strict)" bash -c "cd '$PIPELINE_DIR' && dbt test $DBT_TARGET_FLAG $DBT_EXCLUDE_FLAG"
        fi
    else
        echo "  ⚠ dbt non installé, phase skipped. Installer : pip install dbt-bigquery"
    fi
fi

# --- 3. EXPORT --------------------------------------------------------------
if should_run export; then
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "═  3/4  EXPORT — BQ → JSONs du front"
    echo "════════════════════════════════════════════════════════"
    # export_all.py orchestre déjà l'ensemble des exports domaine.
    run_step "Export complet" \
        $PYTHON "$PIPELINE_DIR/scripts/export/export_all.py" || \
        soft_fail "export_all a échoué (souvent : creds BQ manquantes)"
fi

# --- 4. ENRICH --------------------------------------------------------------
if should_run enrich; then
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "═  4/4  ENRICH — Sirene / LLM grounded / thématique"
    echo "════════════════════════════════════════════════════════"

    # 4a — tier2 bénéficiaires (gratuit, API Sirene, 20 workers)
    run_step "Bénéficiaires — tier2 Sirene ≥10k€" \
        $PYTHON "$PIPELINE_DIR/scripts/enrich/enrich_beneficiaire_grounded_llm.py" \
        --mode tier2

    # 4b — tier1 bénéficiaires (LLM payant, optionnel)
    if $TIER1; then
        if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
            echo "  ⚠ --tier1 demandé mais ANTHROPIC_API_KEY absente — phase skipped"
        else
            run_step "Bénéficiaires — tier1 LLM grounded ≥80k€" \
                $PYTHON "$PIPELINE_DIR/scripts/enrich/enrich_beneficiaire_grounded_llm.py" \
                --mode tier1
        fi
    else
        echo ""
        echo "  ℹ tier1 LLM non lancé (ajoute --tier1 pour l'activer, coût ~quelques €)"
    fi

    # 4c — autres enrichements (géo AP + thématique) via l'orchestrateur existant.
    # En mode --cron-safe, on skip : ces étapes sont 100% LLM (Gemini), donc
    # coûteuses et risquées en non-interactif. Les nouvelles lignes restent
    # sans thématique/géo jusqu'à la prochaine session manuelle.
    if $CRON_SAFE; then
        echo ""
        echo "  ℹ --cron-safe : run_enrichment.py (LLM Gemini) skipped."
        echo "    Les nouvelles lignes resteront non enrichies (thématique/géo)"
        echo "    jusqu'à la prochaine session manuelle."
    elif [[ -f "$PIPELINE_DIR/scripts/enrich/run_enrichment.py" ]]; then
        run_step "Autres enrichissements (géo + thématique)" \
            $PYTHON "$PIPELINE_DIR/scripts/enrich/run_enrichment.py" || \
            soft_fail "run_enrichment.py a échoué"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "✓ Pipeline terminé"
echo "════════════════════════════════════════════════════════"
