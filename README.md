# HorizonDB AI training

### From documents to relevant answers, starting with better retrieval.

![Training workflow: load documents, chunk and embed with an AI Pipeline, then retrieve with DiskANN, BM25, and hybrid search inside Azure HorizonDB.](assets/training-workflow.svg)

Build the retrieval foundation for AI assistants using **Azure HorizonDB and SQL**.
This guided training takes you from complete source documents to searchable
chunks, embeddings, and ranked results, without building a separate ingestion
service for the walkthrough.

**[Start the hands-on lab](horizondb-lab.md)** ·
**[Open the SQL walkthrough](horizondb-ai-sql-queries-only.sql)** ·
**[Explore HorizonDB](https://learn.microsoft.com/en-us/azure/horizondb/)**

## Why HorizonDB for AI?

Useful AI applications need relevant, up-to-date context, not just a model.
HorizonDB brings document preparation and complementary search techniques into
PostgreSQL, so you can work with your data and retrieval logic through SQL.

| What your application needs | What you will explore |
| --- | --- |
| Understand meaning, not only exact words | Embeddings and **DiskANN vector search** for semantic similarity |
| Find precise terms and phrases | **BM25 full-text search** with `pg_textsearch` |
| Combine semantic and keyword relevance | **Hybrid retrieval** using reciprocal rank fusion (RRF) |
| Turn source documents into searchable context | **AI Pipelines** that chunk and embed documents |
| Use embeddings without wiring a separate model endpoint in the lab | **AI Model Management** and registered embedding models |
| Run document preparation durably | Pipeline execution and status inspection backed by `pg_durable` |

This is a small, functional learning exercise, **not a performance benchmark**.
The sample data demonstrates how the pieces connect; it does not establish
production-scale latency, recall, or throughput.

## What this training is based on

The training follows the two files included in this repository:

| File | Purpose |
| --- | --- |
| [`horizondb-lab.md`](horizondb-lab.md) | Guided instructions, prerequisites, explanations, and SQL blocks |
| [`horizondb-ai-sql-queries-only.sql`](horizondb-ai-sql-queries-only.sql) | The companion SQL, arranged in the same eight parts |

The scenario is a **Hyro SPOT document-retrieval proof of concept** using six
complete, synthetic documents: appointment scheduling, visitor parking, and
records requests for two fictional plans.

You will use a dedicated `hyro_ai_lab` schema, load the source documents into
`spot_documents`, and build searchable chunks in `spot_demo_v1`. The pipeline
uses 512-size chunks with 128 overlap and 1,536-dimensional embeddings.

> **Synthetic content only.** The examples contain no patient data and provide
> no clinical advice. This is a retrieval lab, not a medical assistant or a
> complete answer-generating application.

## Your hands-on journey

| Part | Activity | What to look for |
| --- | --- | --- |
| 1 | Verify extensions and registered models | Required extensions are present and an embedding model is available |
| 2 | Load the six complete documents | Source text and plan membership are stored before chunking |
| 3 | Create and run a durable AI Pipeline | Documents are chunked and embedded; the run completes successfully |
| 4 | Inspect the searchable output | Each chunk has a source document ID, chunk index, text, and embedding |
| 5 | Build a DiskANN index and run vector search | Semantically similar chunks are retrieved by cosine distance |
| 6 | Build a BM25 index and run keyword search | Chunks are ranked by keyword relevance |
| 7 | Combine both searches using RRF | Up to 50 candidates from each search contribute to the top 10 results |
| 8 | Review an optional `ai.search` example | A higher-level hybrid-search API to verify against your target build |

The final example is **optional and commented out in the SQL file**.
Verify the `ai.search` contract on your HorizonDB build before running it.

## Before you begin

You need an Azure subscription with access to HorizonDB and permission to
configure the cluster and create database objects. Azure resources and model
usage may incur charges.

1. **Create a dedicated lab cluster and database.**
   Follow the [cluster quickstart](https://learn.microsoft.com/en-us/azure/horizondb/configure-maintain/quickstart-create-cluster)
   and allow your client IP through the cluster's networking configuration.
2. **Enable AI Model Management.**
   Follow the [model-management setup](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-model-management#enable-ai-model-management).
   The lab checks the registered models before creating embeddings.
3. **Configure the required extensions.**
   Follow the lab guide's parameter-group instructions: add `pg_textsearch`
   and `pg_durable` to `azure.extensions`, and add `pg_textsearch` to
   `shared_preload_libraries`, preserving existing values.
   The lab uses `vector`, `pg_diskann`, `pg_textsearch`, `pg_durable`, and `azure_ai`.
4. **Connect from VS Code or your SQL client.**
   The [PostgreSQL extension for VS Code](https://learn.microsoft.com/en-us/azure/horizondb/development/vs-code-extension/vs-code-connect)
   provides the connection experience used in the training.

Then open **[the lab guide](horizondb-lab.md)** and execute its SQL blocks
individually, in order, against the same database connection.

> **Run safely:** Keep autocommit enabled. Do not execute the entire script as
> one transaction. Parts 1-3 create persistent objects, and pipeline names are
> database-wide: do not blindly rerun setup. Stop on errors, and wait for the
> durable pipeline run to commit and complete successfully before Part 4.
> Empty output alone is not evidence that the pipeline succeeded.

Never put passwords, connection strings, access tokens, endpoints, or API keys
in committed files. Keep connection settings in your approved local tooling.

## Try questions that reveal different retrieval behavior

Use the supplied appointment query first. Then experiment with alternatives
such as these, changing the query text consistently in both branches of the
hybrid example:

| Example question | What to explore |
| --- | --- |
| "How do I schedule an appointment?" | Compare the scheduling passages returned by vector, BM25, and hybrid search |
| "Where can visitors park?" | Look for the parking document even when the question paraphrases the source |
| "How do I request a copy of my records?" | Inspect keyword relevance for a specific administrative task |
| "Does submitting an appointment request confirm my appointment?" | Check whether retrieved passages contain the distinction needed to answer |

Inspect the returned passages rather than assuming any search method will
always produce the best result. The sample intentionally includes different
Plan A and Plan B scheduling workflows.

## Where these patterns can help

These are **application ideas**, not additional implemented labs:

| Use case | How the training pattern applies |
| --- | --- |
| Administrative self-service | Retrieve scheduling, parking, and records-request guidance from approved documents |
| Customer-support copilots | Combine exact product terms with semantic matches across help-center articles |
| Internal knowledge assistants | Retrieve relevant policy, onboarding, and operational documentation |
| Product-documentation search | Blend keyword precision with natural-language questions about features |
| Agent grounding | Supply retrieved passages as context to an application-side model or agent |

## What you still need for production

The walkthrough intentionally stops at ranked retrieval results.

- **Authorization and isolation:** The sample hybrid query is unfiltered.
  Enforce health-system, tenant, plan, and user-access boundaries before using
  retrieved content to personalize answers.
- **Answer generation and citations:** Add application-side prompts, source
  attribution, and appropriate handling when evidence is missing or conflicting.
- **Evaluation:** Measure relevance, recall, latency, cost, chunk quality, and
  freshness against your own documents and representative questions.
- **Safety and operations:** Add appropriate healthcare-safety controls,
  monitoring, governance, and a tested ingestion/update lifecycle.
  Do not route urgent or emergency requests through this demo.

## Learn more

- [Azure HorizonDB documentation](https://learn.microsoft.com/en-us/azure/horizondb/)
- [AI Model Management](https://learn.microsoft.com/en-us/azure/horizondb/ai/ai-model-management)
- [BM25 full-text search and extension setup](https://learn.microsoft.com/en-us/azure/horizondb/ai/full-text-search)
- [Connect using VS Code](https://learn.microsoft.com/en-us/azure/horizondb/development/vs-code-extension/vs-code-connect)

Feature availability and SQL interfaces can vary by HorizonDB build and region.
Use the linked documentation and the checks in the lab guide for your environment.
