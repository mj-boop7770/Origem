-- ============================================================
-- ORIGEM — Schema pipeline collecte entreprises
-- entreprises + sources + sources_config + runs_log
-- ============================================================

PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------
-- 1. ENTREPRISES — une ligne unique par entreprise (dédupliquée)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS entreprises (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    nom_normalise   TEXT NOT NULL UNIQUE,   -- "cimextur" (minuscule, sans Lda/SARL/SA)
    nom_original    TEXT NOT NULL,
    secteur         TEXT,
    ville           TEXT,
    pais            TEXT DEFAULT 'Moçambique',
    cree_le         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_entreprises_secteur ON entreprises(secteur);
CREATE INDEX IF NOT EXISTS idx_entreprises_ville ON entreprises(ville);


-- ------------------------------------------------------------
-- 2. SOURCES — chaque citation d'une entreprise par une source
--    Une même entreprise peut avoir plusieurs lignes ici
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sources (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    entreprise_id   INTEGER NOT NULL REFERENCES entreprises(id) ON DELETE CASCADE,
    source_nom      TEXT NOT NULL,      -- 'paginasamarelas' / 'apiex' / 'mmo' / 'linkedin' / 'us_embassy'
    url             TEXT,
    confiance       TEXT NOT NULL CHECK (confiance IN ('haute','moyenne','basse')),
    date_trouve     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sources_entreprise ON sources(entreprise_id);
CREATE INDEX IF NOT EXISTS idx_sources_nom ON sources(source_nom);


-- ------------------------------------------------------------
-- 3. SOURCES_CONFIG — pilotage du Worker Cron : quelles sources
--    scanner, à quelle fréquence, avec quelle méthode déjà validée
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sources_config (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    nom                 TEXT NOT NULL UNIQUE,   -- 'mmo_emprego', 'paginas_amarelas', 'apiex_noticias'...
    methode             TEXT NOT NULL CHECK (methode IN ('scraping_direct','tavily_extract','tavily_search')),
    url                 TEXT,
    confiance           TEXT NOT NULL CHECK (confiance IN ('haute','moyenne','basse')),
    frequence_jours     INTEGER NOT NULL DEFAULT 30,
    derniere_execution  DATETIME,
    methode_confirmee   INTEGER NOT NULL DEFAULT 0 CHECK (methode_confirmee IN (0,1)),  -- 1 = code/regex suffit, 0 = teste encore Groq
    score_dernier_test  INTEGER,   -- score des 9 signaux au dernier passage
    actif               INTEGER NOT NULL DEFAULT 1 CHECK (actif IN (0,1))
);


-- ------------------------------------------------------------
-- 4. RUNS_LOG — historique d'exécution du cron, pour surveiller
--    la consommation Tavily et détecter les échecs
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS runs_log (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    date_run                DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    source_nom              TEXT,
    entreprises_trouvees    INTEGER DEFAULT 0,
    entreprises_nouvelles   INTEGER DEFAULT 0,
    credits_tavily_utilises INTEGER DEFAULT 0,
    erreurs                 TEXT
);

CREATE INDEX IF NOT EXISTS idx_runs_log_date ON runs_log(date_run);


-- ------------------------------------------------------------
-- 5. VUE — trust score calculé par entreprise
--    haute = 3 pts | moyenne = 2 pts | basse = 1 pt
--    ≥6 Vérifiée | 3-5 Probable | <3 Non confirmée
-- ------------------------------------------------------------
CREATE VIEW IF NOT EXISTS v_entreprises_confianca AS
SELECT
    e.*,
    COUNT(s.id) AS nb_sources,
    COALESCE(SUM(CASE s.confiance
        WHEN 'haute' THEN 3
        WHEN 'moyenne' THEN 2
        WHEN 'basse' THEN 1
        ELSE 0 END), 0) AS trust_score,
    CASE
        WHEN COALESCE(SUM(CASE s.confiance
            WHEN 'haute' THEN 3 WHEN 'moyenne' THEN 2 WHEN 'basse' THEN 1 ELSE 0 END), 0) >= 6
            THEN 'Verificada'
        WHEN COALESCE(SUM(CASE s.confiance
            WHEN 'haute' THEN 3 WHEN 'moyenne' THEN 2 WHEN 'basse' THEN 1 ELSE 0 END), 0) >= 3
            THEN 'Provavel'
        ELSE 'Nao confirmada'
    END AS estatuto
FROM entreprises e
LEFT JOIN sources s ON s.entreprise_id = e.id
GROUP BY e.id;


-- ------------------------------------------------------------
-- 6. Config de départ — les sources identifiées dans ta recherche
-- ------------------------------------------------------------
INSERT INTO sources_config (nom, methode, url, confiance, frequence_jours) VALUES
('mmo_emprego', 'scraping_direct', 'https://emprego.mmo.co.mz/org', 'moyenne', 30),
('paginas_amarelas_import_export', 'tavily_extract', 'https://paginasamarelas.co.mz', 'moyenne', 30),
('apiex_noticias', 'tavily_search', 'https://apiex.gov.mz/noticias', 'haute', 7),
('us_embassy_directory', 'tavily_extract', 'https://trade.gov', 'haute', 60),
('bau_veille', 'tavily_search', 'https://bau.gov.mz', 'basse', 90);
