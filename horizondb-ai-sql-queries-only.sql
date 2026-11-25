-- Azure HorizonDB document retrieval training: synthetic workplace guides.
-- Execute section by section on the primary with autocommit enabled.
-- Stop on errors; do not execute the entire script as one transaction.
-- Setup is run-once. Wait for Part 3 completion before continuing.
-- Reference: https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-pipelines

---====================================================
-- ## Part 1: Verify prerequisites and the embedding model
---====================================================
-- Allowlist extensions and preload pg_durable and pg_textsearch first.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS pg_durable;
CREATE EXTENSION IF NOT EXISTS azure_ai;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_diskann', 'pg_textsearch', 'pg_durable', 'azure_ai')
ORDER BY extname;

-- STOP if azure_ai is older than 2.5.6. See the lab's upgrade instructions.
SELECT name, version, installed
FROM pg_available_extension_versions
WHERE name = 'azure_ai'
ORDER BY version;

---====================================================
-- ## Part 1B: Register custom models in AIMM (Optional)
---====================================================
-- Skip this section for managed models. Uncomment only the registrations needed
-- in your approved local tooling; replace placeholders there, never in Git.
-- Chat and reranking models are optional extensions, not required for this lab.

-- Register a custom chat model from Microsoft Foundry.
-- SELECT model_registry.model_add(
--     'gpt-5-byom',
--     'https://<your-resource-name>.openai.azure.com/',
--     '<chat-deployment-name>',
--     'gpt-5.4',
--     NULL,
--     'subscription-key',
--     '<endpoint-key>'
-- );

-- Register a custom embedding model.
-- SELECT model_registry.model_add(
--     'text-embedding-3-small-byom',
--     'https://<your-resource-name>.openai.azure.com/',
--     '<embedding-deployment-name>',
--     'text-embedding-3-small',
--     NULL,
--     'subscription-key',
--     '<endpoint-key>'
-- );

-- Register a custom reranking model.
-- SELECT model_registry.model_add(
--     'reranker-byom',
--     'https://<your-resource-name>.services.ai.azure.com/',
--     '<reranker-deployment-name>',
--     'Cohere-rerank-v4.0-fast',
--     NULL,
--     'subscription-key',
--     '<endpoint-key>'
-- );

-- For BYOM, replace default-embedding with text-embedding-3-small-byom in the
-- alias check, probe, pipeline, and queries (embedding_model in ai.search).
-- Registration does not validate connectivity; require a successful probe.
SELECT alias, model_name, status
FROM model_registry.model_list_all()
WHERE alias = 'default-embedding';

-- Require embedding_dimensions = 1536 and embedding_ready = true.
WITH probe AS (
    SELECT ai.embed(
        text => 'connectivity test',
        model => 'default-embedding',
        dimensions => 1536
    )::vector AS embedding
)
SELECT vector_dims(embedding) AS embedding_dimensions,
       embedding IS NOT NULL AND vector_dims(embedding) = 1536 AS embedding_ready
FROM probe;

CREATE SCHEMA training_ai_lab;
SET search_path = training_ai_lab, public;

---====================================================
-- ## Part 2: Load complete source documents
---====================================================
-- One row per document/team membership, not one row per precomputed chunk.
CREATE TABLE training_documents (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       text NOT NULL,
    source_url  text NOT NULL,
    team_id     text NOT NULL,
    content     text NOT NULL CHECK (btrim(content) <> ''),
    UNIQUE (source_url, team_id)
);

INSERT INTO training_documents (title, source_url, team_id, content) VALUES
    ('Book a meeting room',
     'https://training.example/team-a/room-booking', 'team-a',
     $document$In this fictional workplace, Team A books meeting rooms through the staff portal. Open the room booking page, choose a building, and select a preferred room and time window. Submit the booking request through the portal.

Submitting a request does not confirm a reservation. The facilities team reviews the request and posts the confirmed room, date, and time in the portal. Check the confirmation before inviting visitors. If no confirmation appears, contact facilities through the portal message center.

To change a request, open its details page and select the change option. Facilities reviews changes using the same confirmation process.$document$),
    ('Book a meeting room',
     'https://training.example/team-b/room-booking', 'team-b',
     $document$In this fictional workplace, Team B books meeting rooms by contacting the facilities team. Unlike Team A, Team B cannot submit new room booking requests through the staff portal. Use the facilities contact in the team directory and provide a preferred building, room, and time window.

Facilities reviews room availability and confirms the room, date, and time. A preferred window is not a confirmed reservation. Wait for confirmation before inviting visitors. If confirmation is missing, contact facilities again using the team directory.

To change or cancel a reservation, contact the same facilities team. The team records the change and provides an updated confirmation.$document$),
    ('Visitor parking and directions',
     'https://training.example/parking', 'team-a',
     $document$In this fictional workplace, visitor parking is in the north garage. Follow the visitor signs from the campus entrance to the garage entrance. The main building entrance is on the first floor.

After parking, use the marked pedestrian route to the main entrance. The visitor information desk is inside the lobby and can provide directions to meeting rooms and administrative offices. Keep the parking ticket available for the return trip. These directions are the same for Team A and Team B.$document$),
    ('Visitor parking and directions',
     'https://training.example/parking', 'team-b',
     $document$In this fictional workplace, visitor parking is in the north garage. Follow the visitor signs from the campus entrance to the garage entrance. The main building entrance is on the first floor.

After parking, use the marked pedestrian route to the main entrance. The visitor information desk is inside the lobby and can provide directions to meeting rooms and administrative offices. Keep the parking ticket available for the return trip. These directions are the same for Team A and Team B.$document$),
    ('Request an archived project document',
     'https://training.example/archive', 'team-a',
     $document$In this fictional workplace, the archive team accepts project document requests through the staff portal. Open the archive request page and choose the project and document type. Submit the request using the archive form rather than a room booking message.

The archive team posts an acknowledgment in the portal and provides instructions for the next step. Check the request status page for updates. If the project or document is not listed, contact the archive team through the portal message center. These instructions are the same for Team A and Team B. This sample contains no real project files or personal information.$document$),
    ('Request an archived project document',
     'https://training.example/archive', 'team-b',
     $document$In this fictional workplace, the archive team accepts project document requests through the staff portal. Open the archive request page and choose the project and document type. Submit the request using the archive form rather than a room booking message.

The archive team posts an acknowledgment in the portal and provides instructions for the next step. Check the request status page for updates. If the project or document is not listed, contact the archive team through the portal message center. These instructions are the same for Team A and Team B. This sample contains no real project files or personal information.$document$);

SELECT count(*) AS source_document_count
FROM training_ai_lab.training_documents;

---====================================================
-- ## Part 3: Chunk and embed documents in one durable pipeline
---====================================================
-- Run once into this empty sink. doc_id is batch-local, not training_documents.id.
-- Chunking does not preserve source columns, including team_id.
CREATE TABLE document_chunks (
    doc_id      INT,
    chunk_index INT,
    chunk_text  TEXT,
    embedding   vector(1536)
);

SELECT column_name, data_type, udt_name
FROM information_schema.columns
WHERE table_schema = 'training_ai_lab' AND table_name = 'document_chunks'
ORDER BY ordinal_position;

SELECT ai.create_pipeline(
    name => 'training_document_retrieval',
    source => ai.table_source(
        table_name => 'training_documents',
        incremental_column => 'id',
        schema_name => 'training_ai_lab'
    ),
    steps => ARRAY[
        ai.chunk_step(
            input => 'content',
            chunk_size => 512,
            overlap => 128
        ),
        ai.embed_step(
            input => 'chunk_text',
            dimensions => 1536,
            model => 'default-embedding'
        )
    ],
    trigger => 'manual',
    sink => ai.table_sink(
        table_name => 'document_chunks',
        schema_name => 'training_ai_lab'
    )
);

SELECT ai.explain('training_document_retrieval');
SELECT ai.run('training_document_retrieval');

-- STOP HERE: ai.run submits asynchronously; let it commit before polling.
-- Require last_run_status = 'completed'. On failed/terminated, inspect error.
SELECT * FROM ai.status('training_document_retrieval');

SELECT id, instance_id, status, rows_processed, error, started_at, completed_at
FROM ai.pipeline_runs
WHERE pipeline_name = 'training_document_retrieval'
ORDER BY id DESC
LIMIT 5;

---====================================================
-- ## Part 4: Verify searchable chunks
---====================================================
-- Continue only after the run completes successfully.
SELECT *
FROM training_ai_lab.document_chunks
ORDER BY doc_id, chunk_index
LIMIT 10;

-- Require chunk_count > 0, empty_chunks = 0, and invalid_embeddings = 0.
SELECT
    count(*) AS chunk_count,
    count(*) FILTER (WHERE chunk_text IS NULL OR btrim(chunk_text) = '') AS empty_chunks,
    count(*) FILTER (WHERE embedding IS NULL OR vector_dims(embedding) <> 1536) AS invalid_embeddings
FROM training_ai_lab.document_chunks;

-- Require invalid_chunk_ids = 0 and no duplicate (doc_id, chunk_index) rows.
SELECT count(*) FILTER (WHERE doc_id IS NULL OR chunk_index IS NULL) AS invalid_chunk_ids
FROM training_ai_lab.document_chunks;

SELECT doc_id, chunk_index, count(*) AS duplicate_count
FROM training_ai_lab.document_chunks
GROUP BY doc_id, chunk_index
HAVING count(*) > 1;

---====================================================
-- ## Part 5: Add DiskANN and run vector search
---====================================================
CREATE INDEX document_chunks_embedding_diskann_idx
    ON training_ai_lab.document_chunks USING diskann (embedding vector_cosine_ops);

SELECT *
FROM training_ai_lab.document_chunks
ORDER BY embedding <=> ai.embed(
    text => 'How do I book a meeting room?',
    model => 'default-embedding',
    dimensions => 1536
)::vector(1536)
LIMIT 5;

---====================================================
-- ## Part 6: Add BM25 and run keyword search
---====================================================
CREATE INDEX document_chunks_bm25_idx
    ON training_ai_lab.document_chunks USING bm25 (chunk_text)
    WITH (text_config = 'english');

SELECT chunk_text, chunk_text <@> to_bm25query(
        'How do I book a meeting room?', 'training_ai_lab.document_chunks_bm25_idx'
    ) AS bm25_score
FROM training_ai_lab.document_chunks
ORDER BY bm25_score
LIMIT 10;

---====================================================
-- ## Part 7: Hybrid retrieval with reciprocal rank fusion
---====================================================
-- (doc_id, chunk_index) identifies chunks only in this single-run sink.
WITH
params AS (
    SELECT
        to_bm25query(
            'How do I book a meeting room?', 'training_ai_lab.document_chunks_bm25_idx'
        ) AS q_bm25,
        ai.embed(
            text => 'How do I book a meeting room?',
            model => 'default-embedding',
            dimensions => 1536
        )::vector(1536) AS q_vec
),
bm25 AS (
    SELECT
        p.doc_id, p.chunk_index,
        ROW_NUMBER() OVER (ORDER BY p.chunk_text <@> params.q_bm25) AS bm25_rank
    FROM training_ai_lab.document_chunks AS p
    CROSS JOIN params
    ORDER BY p.chunk_text <@> params.q_bm25
    LIMIT 50
),
vec AS (
    SELECT
        p.doc_id, p.chunk_index,
        ROW_NUMBER() OVER (ORDER BY p.embedding <=> params.q_vec) AS vec_rank
    FROM training_ai_lab.document_chunks AS p
    CROSS JOIN params
    ORDER BY p.embedding <=> params.q_vec
    LIMIT 50
)
SELECT
    p.doc_id, p.chunk_index, p.chunk_text,
    (1.0 / (60 + COALESCE(b.bm25_rank, 1000)))
        + (1.0 / (60 + COALESCE(v.vec_rank, 1000))) AS rrf_score
FROM training_ai_lab.document_chunks AS p
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
-- Verify the installed signature before uncommenting the example.
SELECT p.oid::regprocedure AS function_signature,
       pg_get_function_arguments(p.oid) AS arguments
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'ai' AND p.proname = 'search';

-- SELECT chunks.doc_id, chunks.chunk_index, chunks.chunk_text,
--        result.match_type, result.score
-- FROM ai.search(
--     query => 'How do I book a meeting room?',
--     source_table => 'training_ai_lab.document_chunks',
--     search_type => 'hybrid',
--     top_k => 10,
--     content_column => 'chunk_text',
--     embedding_column => 'embedding',
--     embedding_model => 'default-embedding',
--     rerank => false
-- ) AS result
-- JOIN training_ai_lab.document_chunks AS chunks ON chunks.ctid = result.ctid
-- ORDER BY result.score DESC;
