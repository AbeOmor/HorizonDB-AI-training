-- Hyro SPOT: HorizonDB RAG POC (synthetic, nonclinical content; no patient data).

---====================================================
-- ## Part 1: Verify prerequisites and the embedding model
---====================================================
-- Provision/allowlist these extensions before running this as a pipeline owner.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS pg_durable;
CREATE EXTENSION IF NOT EXISTS azure_ai;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_diskann', 'pg_textsearch', 'pg_durable', 'azure_ai')
ORDER BY extname;

---====================================================
-- ## Part 1B: Register custom models in AIMM (Optional)
---====================================================

-- Register a custom model from Microsoft Foundry

SELECT model_registry.model_add(
    'gpt-5-byom',                                       -- model alias
    'https://abes-demo-ai-foundry.openai.azure.com/openai/v1',      -- model endpoint
    'gpt-5.4',                                 -- deployment name
    'gpt-5.4',                                            -- model name
    NULL,                               -- API version
    'subscription-key',                                 -- auth type
    '<key>'                               -- endpoint key
);

-- Register a custom embedding model

SELECT model_registry.model_add(
    'text-embedding-3-small-byom',                      -- model alias
    'https://abes-demo-ai-foundry.openai.azure.com/openai/v1',      -- model endpoint
    'text-embedding-3-small',                -- deployment name
    'text-embedding-3-small',                           -- model name
    NULL,                               -- API version
    'subscription-key',                                 -- auth type
    '<key>'                               -- endpoint key
);

-- Register a reranking embedding model

SELECT model_registry.model_add(
    'reranker-byom',                      -- model alias
    'https://abes-demo-ai-foundry.openai.azure.com/openai/v1',      -- model endpoint
    'Cohere-rerank-v4.0-fast',                -- deployment name
    'Cohere-rerank-v4.0-fast',                           -- model name
    NULL,                               -- API version
    'subscription-key',                                 -- auth type
    '<key>'                               -- endpoint key
);

SELECT * FROM model_registry.model_list_all();

CREATE SCHEMA hyro_ai_lab;
SET search_path = hyro_ai_lab, public;

---====================================================
-- ## Part 2: Load complete source documents
---====================================================

-- One row per document/plan membership, not one row per precomputed chunk.
-- An actual build must also carry its health-system/tenant identity;
-- this dedicated POC contains only one synthetic health system.
CREATE TABLE spot_documents (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       text NOT NULL,
    source_url  text NOT NULL,
    plan_id     text NOT NULL,
    content     text NOT NULL CHECK (btrim(content) <> ''),
    UNIQUE (source_url, plan_id)
);

INSERT INTO spot_documents (title, source_url, plan_id, content) VALUES
    ('Schedule a primary care appointment',
     'https://hyro-poc.example/plan-a/appointments', 'plan-a',
     $document$For this synthetic health system, Plan A members request a primary care appointment through the member portal. Open the scheduling page, choose primary care, and select a preferred location. The portal displays available request windows for that location. Choose a window and submit the appointment request.

Submitting a request does not confirm an appointment. The scheduling team reviews the request and posts the confirmed date, time, and location in the member portal. Members should check the confirmation before making travel arrangements. If no confirmation appears, contact the scheduling team through the portal message center.

To change an existing request, open the appointment details page and select the change option. The scheduling team reviews changes using the same confirmation process. This synthetic guide describes administrative scheduling only and does not provide clinical advice.$document$),
    ('Schedule a primary care appointment',
     'https://hyro-poc.example/plan-b/appointments', 'plan-b',
     $document$For this synthetic health system, Plan B members request primary care appointments by contacting the scheduling team. Unlike the Plan A workflow, the Plan B member portal does not accept new primary care appointment requests. Use the scheduling contact listed in the plan directory and provide a preferred location and request window.

The scheduling team reviews available appointment times and confirms the date, time, and location with the member. A preferred window is not a confirmed appointment. Members should wait for confirmation before making travel arrangements. If a confirmation is missing, contact the scheduling team again using the plan directory.

To change or cancel a confirmed appointment, contact the same scheduling team. The team records the change and provides an updated confirmation. This synthetic guide covers administrative scheduling only and does not provide clinical advice.$document$),
    ('Visitor parking and directions',
     'https://hyro-poc.example/parking', 'plan-a',
     $document$In this synthetic example, visitor parking is in the north garage. Follow the visitor signs from the campus entrance to the garage entrance. The main building entrance is on the first floor.

After parking, use the marked pedestrian route to the main entrance. The visitor information desk is inside the lobby and can provide directions to administrative offices. Keep the parking ticket available for the return trip. These directions are the same for Plan A and Plan B members.$document$),
    ('Visitor parking and directions',
     'https://hyro-poc.example/parking', 'plan-b',
     $document$In this synthetic example, visitor parking is in the north garage. Follow the visitor signs from the campus entrance to the garage entrance. The main building entrance is on the first floor.

After parking, use the marked pedestrian route to the main entrance. The visitor information desk is inside the lobby and can provide directions to administrative offices. Keep the parking ticket available for the return trip. These directions are the same for Plan A and Plan B members.$document$),
    ('Request a copy of your records',
     'https://hyro-poc.example/records', 'plan-a',
     $document$In this synthetic example, the records office accepts document requests through the member portal. Open the records request page and choose the type of document requested. Submit the request using the portal form rather than an appointment scheduling message.

The records office posts an acknowledgment in the portal and provides instructions for the next administrative step. Check the request status page for updates. If the requested document is not listed, contact the records office through the portal message center. This sample contains no patient records or personal information.$document$),
    ('Request a copy of your records',
     'https://hyro-poc.example/records', 'plan-b',
     $document$In this synthetic example, the records office accepts document requests through the member portal. Open the records request page and choose the type of document requested. Submit the request using the portal form rather than an appointment scheduling message.

The records office posts an acknowledgment in the portal and provides instructions for the next administrative step. Check the request status page for updates. If the requested document is not listed, contact the records office through the portal message center. This sample contains no patient records or personal information.$document$);

---====================================================
-- ## Part 3: Chunk and embed documents in one durable pipeline
---====================================================

CREATE TABLE spot_demo_v1 (
    doc_id      INT,
    chunk_index INT,
    chunk_text  TEXT,
    embedding   vector(1536)
);

SELECT ai.create_pipeline(
    name => 'hyro_spot_documents_byom',
    source => ai.table_source(
        table_name => 'spot_documents',
        schema_name => 'hyro_ai_lab'
    ),
    steps => ARRAY[
        ai.chunk(
            input => 'content',
            chunk_size => 512,
            overlap => 128
        ),
        ai.embed(
            input => 'chunk_text',
            dimensions => 1536,
            model => 'text-embedding-3-small-byom'
        )
    ],
    trigger => 'manual',
    sink => ai.table_sink(
        table_name => 'spot_demo_v1',
        schema_name => 'hyro_ai_lab'
    )
);

SELECT ai.explain('hyro_spot_documents_byom');
SELECT ai.run('hyro_spot_documents_byom');
-- SELECT ai.drop_pipeline('hyro_spot_documents_byom');

-- STOP HERE until the durable run has committed and completed successfully.
-- Reissue status as needed. Empty output is not proof of success.
SELECT * FROM ai.status('hyro_spot_documents');

---====================================================
-- ## Part 4: Verify searchable chunks
---====================================================

SELECT *
FROM hyro_ai_lab.spot_demo_v1
LIMIT 10;

---====================================================
-- ## Part 5: Add DiskANN For more efficient vector search. We will use this for hybrid search.
---====================================================

CREATE INDEX spot_demo_v1_embedding_diskann_idx
    ON hyro_ai_lab.spot_demo_v1 USING diskann (embedding vector_cosine_ops);

SELECT *
FROM hyro_ai_lab.spot_demo_v1
ORDER BY embedding <=> azure_openai.create_embeddings(
    'text-embedding-3-small-byom', 
    'How do I schedule an appointment'
)::vector
LIMIT 5;

---====================================================
-- ## Part 6: Move chunk_text BM25 into PostgreSQL (also the BM25-only fallback)
---====================================================

CREATE INDEX spot_demo_v1_bm25_idx
    ON hyro_ai_lab.spot_demo_v1 USING bm25 (chunk_text)
    WITH (text_config = 'english');

SELECT chunk_text, chunk_text <@> to_bm25query(
        'How do I schedule an appointment', 'hyro_ai_lab.spot_demo_v1_bm25_idx'
        ) AS bm25_score
    FROM hyro_ai_lab.spot_demo_v1
    ORDER BY bm25_score
    LIMIT 10;

---====================================================
-- ## Part 7: Hybrid retrieval with reciprocal rank fusion in one SQL round trip
---====================================================

WITH
params AS (
    SELECT
        to_bm25query(
            'How do I schedule an appointment', 'hyro_ai_lab.spot_demo_v1_bm25_idx'
        ) AS q_bm25,
        azure_openai.create_embeddings(
            'text-embedding-3-small-byom',
            'How do I schedule an appointment',
            dimensions => 1536
        )::vector(1536) AS q_vec
),
bm25 AS (
    SELECT
        p.doc_id, p.chunk_index,
        ROW_NUMBER() OVER (ORDER BY p.chunk_text <@> params.q_bm25) AS bm25_rank
    FROM hyro_ai_lab.spot_demo_v1 AS p
    CROSS JOIN params
    ORDER BY p.chunk_text <@> params.q_bm25
    LIMIT 50
),
vec AS (
    SELECT
        p.doc_id, p.chunk_index,
        ROW_NUMBER() OVER (ORDER BY p.embedding <=> params.q_vec) AS vec_rank
    FROM hyro_ai_lab.spot_demo_v1 AS p
    CROSS JOIN params
    ORDER BY p.embedding <=> params.q_vec
    LIMIT 50
)
SELECT
    p.doc_id, p.chunk_index, p.chunk_text,
    (1.0 / (60 + COALESCE(b.bm25_rank, 1000)))
        + (1.0 / (60 + COALESCE(v.vec_rank, 1000))) AS rrf_score
FROM hyro_ai_lab.spot_demo_v1 AS p
LEFT JOIN bm25 AS b
    ON b.doc_id = p.doc_id AND b.chunk_index = p.chunk_index
LEFT JOIN vec AS v
    ON v.doc_id = p.doc_id AND v.chunk_index = p.chunk_index
WHERE b.doc_id IS NOT NULL OR v.doc_id IS NOT NULL
ORDER BY rrf_score DESC
LIMIT 10;

---====================================================
-- ## Part 8: Optional ai.search demonstration
---====================================================

-- SELECT *
-- FROM ai.search(
--     query => 'How do I schedule a primary care appointment?',
--     source_table => 'hyro_ai_lab.spot_demo_v1',
--     search_type => 'hybrid',
--     embedding_model => 'text-embedding-3-small-byom',
--     rerank_model => 'cohere',
--     top_k => 10,
--     rerank => false
-- ) AS result
-- JOIN hyro_ai_lab.spot_demo_v1 AS chunks ON chunks.ctid = result.ctid
-- ORDER BY result.score DESC;