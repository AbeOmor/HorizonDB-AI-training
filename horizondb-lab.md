# Azure HorizonDB AI lab: document retrieval

## Using this guide

Connect to a new, dedicated Azure HorizonDB lab database on the **primary (read-write) endpoint** using the PostgreSQL extension for Visual Studio Code or your SQL client. Complete the prerequisites before Part 1. Never put passwords, access tokens, endpoints, or API keys in committed files.

Execute SQL blocks individually, in order, on the same connection with autocommit enabled. Do not execute the entire lab as one transaction. Stop on errors. Parts 1-3 create persistent objects; setup is run-once, and pipeline names are database-wide. Do not blindly rerun setup or run both walkthroughs sequentially against the same sink.

This guide and the [companion SQL](horizondb-ai-sql-queries-only.sql) use the same `default-embedding` model, `training_ai_lab` schema, and `training_document_retrieval` pipeline. Wait for the asynchronous run to commit and complete before Part 4.

## About this lab

A fictional workplace knowledge assistant retrieves meeting-room booking, visitor parking, and archived-project-document guidance for Team A and Team B. Six complete synthetic documents demonstrate different booking workflows and shared administrative instructions. No real customer documents or personal information are included.

You will load documents, chunk and embed them in a durable pipeline, validate the output, and compare DiskANN vector search, BM25 keyword search, and hybrid reciprocal rank fusion (RRF). The walkthrough stops at retrieval, not answer generation.

The queries are **unfiltered** and do not enforce team or tenant isolation. Production applications need stable source identity, access controls, citations, evaluation, monitoring, and a tested ingestion/update lifecycle. Chunking drops source metadata during preview; do not infer authorization from the output.

## Prerequisites

### Step 1 - Create a dedicated cluster and database

Follow the [cluster quickstart](https://learn.microsoft.com/en-us/azure/horizondb/configure-maintain/quickstart-create-cluster). Allow your client IP through networking and connect to the primary endpoint. Azure resources and model calls may incur charges.

### Step 2 - Enable AI Model Management

Follow [AI Model Management setup](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-model-management#enable-ai-model-management). Managed models avoid endpoint and key configuration in this lab. Confirm the registered alias in Part 1; aliases are not guaranteed to exist on every instance.

For BYOM instead, follow [manual model registration](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-functions#option-2-manual-setup-with-model-registry) in your approved local tooling. Register an embedding deployment, not a chat or reranking model. Replace `default-embedding` consistently in the connectivity probe, pipeline, query embeddings, and optional `ai.search` call (`embedding_model`). Use the same model and 1,536 dimensions throughout. Registration does not validate endpoint credentials during preview; the connectivity probe is required before pipeline creation. Do not commit endpoint configuration or keys.

### Step 3 - Configure extensions and preloads

In the cluster parameter group, preserve all existing parameter values:

1. Allow the required extensions in `azure.extensions`: `vector`, `pg_diskann`, `azure_ai`, `pg_durable`, and `pg_textsearch`.
2. Add **both `pg_durable` and `pg_textsearch`** to `shared_preload_libraries`.
3. Apply the parameter group and complete any required restart before installing extensions.

If `CREATE EXTENSION pg_durable` reports that it must be loaded via `shared_preload_libraries`, fix the preload and restart first. See [durable functions](https://learn.microsoft.com/en-us/azure/horizondb/development/durable-functions) and [BM25 setup](https://learn.microsoft.com/en-us/azure/horizondb/ai/full-text-search#enable-pg_textsearch).

### Step 4 - Connect and check the API version

Use [the PostgreSQL extension for VS Code](https://learn.microsoft.com/en-us/azure/horizondb/development/vs-code-extension/vs-code-connect) or your SQL client. These examples follow the [AI pipelines documentation](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-pipelines), updated November 17, 2026, and require **`azure_ai` 2.5.6 or later**.

## Part 1: Verify prerequisites and the embedding model

Install and inspect the five required extensions:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS pg_durable;
CREATE EXTENSION IF NOT EXISTS azure_ai;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_diskann', 'pg_textsearch', 'pg_durable', 'azure_ai')
ORDER BY extname;

SELECT name, version, installed
FROM pg_available_extension_versions
WHERE name = 'azure_ai'
ORDER BY version;
```

Stop if `azure_ai` is older than 2.5.6. When 2.5.6 is available, an authorized administrator can run `ALTER EXTENSION azure_ai UPDATE TO '2.5.6';` on the primary in each database that needs upgrading, then recheck the installed version. Do not downgrade a newer version. If 2.5.6 is unavailable, wait for the service update.

The bundled migration preserves existing stored pipeline descriptors and source/sink tables. Do not recreate existing pipelines just for the builder renames. Update pipeline-creation scripts to use `ai.chunk_step`, `ai.embed_step`, `ai.extract_step`, `ai.generate_step`, `ai.rank_step`, and `ai.is_true_step`. Source/sink helpers and management function names are unchanged. See [AI schema migration](https://learn.microsoft.com/en-us/azure/horizondb/ai/migrate-ai-schema).

Builders return JSONB descriptors for deferred work. Unsuffixed `ai.embed`, `ai.generate`, `ai.extract`, `ai.rank`, and `ai.is_true` perform synchronous inference. Use named arguments: embedding builders take `input`, while direct embedding takes `text` and returns `real[]`, which must be cast to `vector` for distance operators.

Confirm that the embedding model is registered and responds:

```sql
SELECT alias, model_name, status
FROM model_registry.model_list_all()
WHERE alias = 'default-embedding';

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
```

Require a registered alias, `embedding_dimensions = 1536`, and `embedding_ready = true`. Stop and fix model configuration if the probe fails or returns a NULL embedding.

```sql
CREATE SCHEMA training_ai_lab;
SET search_path = training_ai_lab, public;
```

## Part 2: Load complete source documents

The pipeline, not the import step, owns chunking and embedding. Each row represents a complete document/team membership. `id` is a monotonic identity column used as the **required incremental watermark** for this insert-only exercise. It advances on inserts, not updates; editing existing documents requires an advancing revision/timestamp watermark and an update-safe ingestion design.

```sql
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
```

Require `source_document_count = 6`. The `.example` URLs are fictional identifiers; the pipeline reads table content, not those URLs.

## Part 3: Chunk and embed documents in one durable pipeline

Create an empty sink with the exact output names for chunking and embedding. The sample uses a chunk size of 512, overlap of 128, and 1,536-dimensional embeddings. Evaluate chunk boundaries for your own corpus.

During preview, `ai.chunk_step` emits a **batch-local row number** as `doc_id`, not `training_documents.id`. It can repeat across batches or incremental runs. Chunking does not retain source columns or preexisting metadata, including `team_id`. This lab submits one small run into an empty sink and checks chunk identity before joining retrieval candidates. Do not join chunks to source rows using `doc_id`, treat it as a durable key, or rerun into the populated sink.

```sql
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
```

Require all four columns above (`embedding` has `udt_name = vector`). If the sink does not exist, `ai.create_pipeline` creates it from inferred outputs, without keys, constraints, or indexes. An existing sink missing a step's output column can silently discard that result while reporting success, so inspect the schema before running and validate values afterward. A custom `output` argument on a builder must match the sink and downstream queries. This lab uses default output names.

```sql
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
```

Creation registers a definition; it does not process existing rows. `ai.run` submits a durable instance and returns **before completion**. Let the submission commit, then poll:

```sql
SELECT * FROM ai.status('training_document_retrieval');

SELECT id, instance_id, status, rows_processed, error, started_at, completed_at
FROM ai.pipeline_runs
WHERE pipeline_name = 'training_document_retrieval'
ORDER BY id DESC
LIMIT 5;
```

**Stop before Part 4 until `last_run_status = completed` and the latest run has completed.** If it fails or is terminated, inspect `error` and `instance_id`. During preview, `ai.status().total_processed` can remain zero even for a completed run; use `ai.pipeline_runs.rows_processed` for per-run progress. Empty output is never proof of success.

Both `manual` and `on_change` require an incremental column. `on_change` still needs an explicit initial `ai.run`; source deletes do not trigger processing, and changes during an active run do not queue another run. This lab intentionally uses manual execution.

## Part 4: Verify searchable chunks

Inspect actual output only after completion. Require nonempty text, valid embeddings, non-NULL chunk identities, and no duplicate `(doc_id, chunk_index)` pairs before retrieval:

```sql
SELECT *
FROM training_ai_lab.document_chunks
ORDER BY doc_id, chunk_index
LIMIT 10;

SELECT
    count(*) AS chunk_count,
    count(*) FILTER (WHERE chunk_text IS NULL OR btrim(chunk_text) = '') AS empty_chunks,
    count(*) FILTER (WHERE embedding IS NULL OR vector_dims(embedding) <> 1536) AS invalid_embeddings
FROM training_ai_lab.document_chunks;

SELECT count(*) FILTER (WHERE doc_id IS NULL OR chunk_index IS NULL) AS invalid_chunk_ids
FROM training_ai_lab.document_chunks;

SELECT doc_id, chunk_index, count(*) AS duplicate_count
FROM training_ai_lab.document_chunks
GROUP BY doc_id, chunk_index
HAVING count(*) > 1;
```

Require `chunk_count > 0`, `empty_chunks = 0`, `invalid_embeddings = 0`, `invalid_chunk_ids = 0`, and no duplicate rows. Inspect the returned text to confirm the intended documents were processed; chunk count is not source document count.

If validation fails, inspect run history and model configuration. A normal rerun can skip rows already checkpointed. For recovery or model/chunking changes, preserve the current sink, backfill into a separate staging sink, wait for completion, and validate before replacement. Do not truncate the current sink before an asynchronous backfill finishes. See [output verification and safe rebuilds](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-pipelines#verify-pipeline-output). Incremental selection does not make this append-only sink update-safe or model calls exactly-once.

## Part 5: Add DiskANN and run vector search

Create a cosine-distance index after embeddings exist, then retrieve five semantically similar chunks. Lower cosine distance is better. This tiny corpus is functional training, not a latency or recall benchmark.

```sql
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
```

## Part 6: Add BM25 and run keyword search

BM25 provides keyword retrieval without a query embedding. Order the `<@>` score ascending.

```sql
CREATE INDEX document_chunks_bm25_idx
    ON training_ai_lab.document_chunks USING bm25 (chunk_text)
    WITH (text_config = 'english');

SELECT chunk_text, chunk_text <@> to_bm25query(
        'How do I book a meeting room?', 'training_ai_lab.document_chunks_bm25_idx'
    ) AS bm25_score
FROM training_ai_lab.document_chunks
ORDER BY bm25_score
LIMIT 10;
```

## Part 7: Hybrid retrieval with reciprocal rank fusion

`params` prepares both queries. Each retrieval branch ranks up to 50 candidates; the join uses the validated single-run chunk pair and includes results from either branch. Return the top ten fused scores using constant 60 and fallback rank 1000 for a missing match.

```sql
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
```

Change the question consistently in both branches when comparing retrieval behavior. Do not assume the highest-ranked passage is sufficient to generate an answer.

## Part 8: Optional ai.search demonstration

The [documented `ai.search` API](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-search) is a higher-level retrieval interface, not an answer generator. Confirm the installed signature first; if absent or incompatible, stop this optional section:

```sql
SELECT p.oid::regprocedure AS function_signature,
       pg_get_function_arguments(p.oid) AS arguments
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'ai' AND p.proname = 'search';
```

The following is commented out in the companion SQL. Run it only after verifying availability and both eligible indexes. Explicit columns and embedding alias keep it consistent with the pipeline:

```sql
SELECT chunks.doc_id, chunks.chunk_index, chunks.chunk_text,
       result.match_type, result.score
FROM ai.search(
    query => 'How do I book a meeting room?',
    source_table => 'training_ai_lab.document_chunks',
    search_type => 'hybrid',
    top_k => 10,
    content_column => 'chunk_text',
    embedding_column => 'embedding',
    embedding_model => 'default-embedding',
    rerank => false
) AS result
JOIN training_ai_lab.document_chunks AS chunks ON chunks.ctid = result.ctid
ORDER BY result.score DESC;
```

Require no more than ten rows, non-NULL scores, and passages joined to the intended table. Inspect `match_type` and both indexes: hybrid mode can fall back to one retrieval method when the other index is missing. `ctid` is a physical row version used only for this same-statement join, not a persistent identifier. Reranking is disabled, so no reranker registration is needed. Outer filters are post-retrieval and are not a replacement for access controls.

## Preview and lifecycle notes

Pipelines read HorizonDB tables; external content must first land in a staging table. Creation, runs, backfills, and other management operations require the primary endpoint and read-write transactions. Pipeline state is not portable across major `pg_durable` versions during preview; drain or pause running pipelines before upgrading.

The lab intentionally leaves its objects available for inspection. Do not drop the pipeline while a run is active. Use the [documented lifecycle](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-pipelines#manage-the-pipeline-lifecycle) when finished, removing only objects created for your dedicated lab.
