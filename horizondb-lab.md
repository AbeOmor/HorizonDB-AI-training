# Azure HorizonDB AI lab: Hyro SPOT document retrieval

## Using this guide

Connect to a new, dedicated Azure HorizonDB lab database using the PostgreSQL extension for Visual Studio Code or your SQL client. AI Model Management should already be enabled. Complete the prerequisites below before running Part 1 to verify and install the required extensions. Never put passwords, access tokens, endpoints, or API keys in this guide or the SQL script.

Execute the SQL blocks individually, in order, using the same database connection with autocommit enabled. Do not execute the entire lab as one transaction. Parts 1-3 create persistent lab objects; do not blindly rerun setup, and stop on errors. Wait for the durable pipeline run to commit and complete successfully before starting Part 4.

AI Pipeline names are database-wide. Run each `ai.create_pipeline()` statement only once per database. If you repeat the lab in the same database, skip creation statements for objects and pipelines that already exist.

## About this lab

Build a retrieval proof of concept using synthetic, nonclinical health-system documents. This lab contains no patient data and does not provide clinical advice.

## Business story

Hyro's SPOT assistant needs to retrieve administrative information about appointment scheduling, visitor parking, and records requests. The sample documents include Plan A and Plan B workflows so you can inspect how source documents become searchable chunks.

During this lab, you use HorizonDB to:

1. Verify the required extensions and registered embedding models.
2. Load complete source documents into `hyro_ai_lab.spot_documents`.
3. Chunk and embed documents in one durable AI Pipeline.
4. Verify the searchable chunks in `hyro_ai_lab.spot_demo_v1`.
5. Create a DiskANN index and retrieve chunks by semantic similarity.
6. Create a BM25 index and retrieve chunks by keyword relevance.
7. Combine the top 50 keyword and vector candidates using reciprocal rank fusion (RRF), returning the top 10 results.
8. Review an optional `ai.search` hybrid-search example.

The hybrid query is an unfiltered retrieval demonstration: it does not enforce plan or tenant isolation. Before personalizing answers, enforce the applicable health-system and plan boundaries. Keep application-side reranking, prompts, answer generation, citations, healthcare-safety overrides, and evaluation outside this SQL walkthrough. Do not send urgent or emergency requests through this demo.

Prerequisites
-------------
Before you begin, perform the following steps:

#### Step 1 - Create an Azure HorizonDB instance
  - [Steps to create an Azure HorizonDB Cluster](https://learn.microsoft.com/en-us/azure/horizondb/configure-maintain/quickstart-create-cluster)
  - For this training, you can choose to Disable High Availability.
  - In the Networking section, ensure to "Add current client IP" to allow list your IP address and connect to the cluster.

#### Step 2 - Enable AI Model Management
  - [Steps to enable AI Model Management](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-model-management#enable-ai-model-management)
  - Enabling it automatically installs azure_ai, pg_durable, vector, and pg_diskann and registers the managed models.

### Step 3 - Allow-list pg_textsearch and pg_durable

Allow both `pg_textsearch` (BM25 full-text search) and `pg_durable` (durable AI Pipelines) in `azure.extensions` through the Azure HorizonDB cluster parameter group. Also preload `pg_textsearch` through `shared_preload_libraries`.

1. In Azure HorizonDB portal view, go to Settings -> Parameters
2. Click on "create" next to Parameter group.
3. In the "Create a parameter group" pane, provide the project details and click on Next.
4. Search for "shared_preload_libraries" and add "pg_textsearch", preserving every existing value.
5. Search for "azure.extensions" and add both "pg_textsearch" and "pg_durable", preserving every existing value.
6. Click create.
7. Once the parameter group deployment completes, go back to "Parameters" pane, select "(change)" and replace the "default" Parameter group by this new parameter group. 

For more details see [Steps to enable pg_textsearch](https://learn.microsoft.com/en-us/azure/horizondb/ai/full-text-search#enable-pg_textsearch)

#### Step 4 - Connect to the Azure HorizonDB cluster
- Connect to Azure HorizonDB cluster using Visual Studio Code. [Quickstart: PostgreSQL Extension for Visual Studio Code for Azure HorizonDB](https://learn.microsoft.com/en-us/azure/horizondb/development/vs-code-extension/vs-code-connect)
- Use a new, dedicated lab database. Execute the SQL blocks below or run [horizondb-ai-sql-queries-only.sql](./horizondb-ai-sql-queries-only.sql) section by section against the same database.
- Note: AI Pipeline names are database-wide, so run each ai.create_pipeline() statement only once in the lab database.

## Part 1: Verify prerequisites and the embedding model

Confirm that all five extensions are installed and inspect the registered models. Create the dedicated `hyro_ai_lab` schema and set the search path for this connection.

```sql
-- Provision/allowlist these extensions before running this as a pipeline owner.

CREATE EXTENSION IF NOT EXISTS vector;
```

```sql
CREATE EXTENSION IF NOT EXISTS pg_diskann;
```

```sql
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
```

```sql
CREATE EXTENSION IF NOT EXISTS pg_durable;
```

```sql
CREATE EXTENSION IF NOT EXISTS azure_ai;
```

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_diskann', 'pg_textsearch', 'pg_durable', 'azure_ai')
ORDER BY extname;
```

```sql
SELECT * FROM model_registry.model_list_all();
```

```sql
CREATE SCHEMA hyro_ai_lab;
```

```sql
SET search_path = hyro_ai_lab, public;
```

## Part 2: Load complete source documents

Load six complete synthetic source documents: appointment scheduling, parking, and records requests for each of two plans. The pipeline, not the import step, owns chunking and embedding.

```sql
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
```

```sql
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
```

## Part 3: Chunk and embed documents in one durable pipeline

Create a searchable output table, then define one manual pipeline that chunks `content` and embeds `chunk_text` into 1,536-dimensional vectors. Run pipeline creation only once. The sample uses a 512 chunk size and 128 overlap; evaluate chunk boundaries against the application baseline before adoption.

```sql
CREATE TABLE spot_demo_v1 (
    doc_id      INT,
    chunk_index INT,
    chunk_text  TEXT,
    embedding   vector(1536)
);
```

```sql
SELECT ai.create_pipeline(
    name => 'hyro_spot_documents',
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
            dimensions => 1536
        )
    ],
    trigger => 'manual',
    sink => ai.table_sink(
        table_name => 'spot_demo_v1',
        schema_name => 'hyro_ai_lab'
    )
);
```

```sql
SELECT ai.explain('hyro_spot_documents');
```

```sql
SELECT ai.run('hyro_spot_documents');
```

**Stop before Part 4.** Let `ai.run` commit, then check the status below. Reissue the status query as needed until the durable run has completed successfully. Empty output is not proof of success. Do not run `ai.drop_pipeline` during the walkthrough.

```sql
-- SELECT ai.drop_pipeline('hyro_spot_documents');

-- STOP HERE until the durable run has committed and completed successfully.
-- Reissue status as needed. Empty output is not proof of success.
SELECT * FROM ai.status('hyro_spot_documents');
```

## Part 4: Verify searchable chunks

Inspect the output only after the durable pipeline run has completed successfully. Each result identifies its source document and chunk index.

```sql
SELECT *
FROM hyro_ai_lab.spot_demo_v1
LIMIT 10;
```

## Part 5: Add DiskANN For more efficient vector search. We will use this for hybrid search.

Create a DiskANN cosine-distance index and retrieve the five nearest chunks for an appointment-scheduling question. Lower cosine distance means greater semantic similarity.

```sql
CREATE INDEX spot_demo_v1_embedding_diskann_idx
    ON hyro_ai_lab.spot_demo_v1 USING diskann (embedding vector_cosine_ops);
```

```sql
SELECT *
FROM hyro_ai_lab.spot_demo_v1
ORDER BY embedding <=> azure_openai.create_embeddings(
    input => 'How do I schedule an appointment'
)::vector
LIMIT 5;
```

## Part 6: Move chunk_text BM25 into PostgreSQL (also the BM25-only fallback)

Create a BM25 index on `chunk_text`, then retrieve the ten best keyword matches. The `<@>` result is ordered ascending, as in the source SQL.

```sql
CREATE INDEX spot_demo_v1_bm25_idx
    ON hyro_ai_lab.spot_demo_v1 USING bm25 (chunk_text)
    WITH (text_config = 'english');
```

```sql
SELECT chunk_text, chunk_text <@> to_bm25query(
        'How do I schedule an appointment', 'hyro_ai_lab.spot_demo_v1_bm25_idx'
        ) AS bm25_score
    FROM hyro_ai_lab.spot_demo_v1
    ORDER BY bm25_score 
    LIMIT 10;
```

## Part 7: Hybrid retrieval with reciprocal rank fusion in one SQL round trip

The `params` CTE prepares the BM25 query and the query embedding. `bm25` and `vec` each rank up to 50 candidates. Join candidates on both `doc_id` and `chunk_index`, include chunks returned by either search, and return the top ten fused results. The example uses RRF constant 60 and substitutes rank 1000 for a missing match, exactly as in the source SQL.

```sql
WITH
params AS (
    SELECT
        to_bm25query(
            'How do I schedule an appointment', 'hyro_ai_lab.spot_demo_v1_bm25_idx'
        ) AS q_bm25,
        azure_openai.create_embeddings(
            'text-embedding-3-small',
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
```

## Part 8: Optional ai.search demonstration

This example is commented out in the source SQL and is intentionally not an executable step. Verify the `ai.search` contract on your target HorizonDB build before running it.

```sql
SELECT *
FROM ai.search(
    query => 'How do I schedule a primary care appointment?',
    source_table => 'hyro_ai_lab.spot_demo_v1',
    search_type => 'hybrid',
    top_k => 10,
    rerank => false
) AS result
JOIN hyro_ai_lab.spot_demo_v1 AS chunks ON chunks.ctid = result.ctid
ORDER BY result.score DESC;
```
