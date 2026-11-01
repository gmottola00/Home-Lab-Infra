-- Accesso in sola lettura di Jarvis ai dati d'uso di LiteLLM.
--
-- Jarvis mostra spesa, errori e latenza del gateway. Le tabelle di LiteLLM
-- contengono però anche i prompt in chiaro (LiteLLM_SpendLogs.messages,
-- .response, .proxy_server_request) e gli hash delle chiavi: il ruolo
-- jarvis_reader non vede NESSUNA tabella. Può solo chiamare le funzioni dello
-- schema jarvis_ro, che girano come owner (SECURITY DEFINER) e restituiscono
-- aggregati senza prompt, senza token e senza traceback.
--
-- I corpi sono stringhe SQL, che Postgres non registra come dipendenze: se un
-- upgrade di LiteLLM cambia una colonna la migrazione Prisma non si blocca,
-- si rompe al più la funzione e Jarvis mostra un errore in quel riquadro.
--
-- Idempotente: lo esegue il Job jarvis-reader-job.yaml a ogni sync ArgoCD.
-- Variabile psql richiesta: reader_password.

\set ON_ERROR_STOP on

-- --- Ruolo ------------------------------------------------------------------

SELECT format('CREATE ROLE jarvis_reader LOGIN PASSWORD %L', :'reader_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jarvis_reader')
\gexec

SELECT format('ALTER ROLE jarvis_reader WITH LOGIN PASSWORD %L', :'reader_password')
\gexec

ALTER ROLE jarvis_reader SET default_transaction_read_only = on;
ALTER ROLE jarvis_reader SET statement_timeout = '5s';

-- Nessun accesso diretto ai dati di LiteLLM, nemmeno se un default cambiasse.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM jarvis_reader;
REVOKE CREATE ON SCHEMA public FROM jarvis_reader;

-- --- Schema e funzioni ------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS jarvis_ro;
REVOKE ALL ON SCHEMA jarvis_ro FROM PUBLIC;
GRANT USAGE ON SCHEMA jarvis_ro TO jarvis_reader;

-- Nome leggibile di una chiave: l'alias, altrimenti il nome mascherato
-- (sk-...Q4dw) che LiteLLM stesso mostra. Mai il token.
CREATE OR REPLACE FUNCTION jarvis_ro.key_label(alias text, masked text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS 'SELECT coalesce(nullif(alias, ''''), masked, ''unknown key'')';

-- Budget e spesa di ogni chiave nel periodo corrente.
CREATE OR REPLACE FUNCTION jarvis_ro.key_budgets()
RETURNS TABLE (alias text, spend double precision, max_budget double precision,
               budget_duration text, budget_reset_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT jarvis_ro.key_label(t.key_alias, t.key_name),
         t.spend,
         t.max_budget,
         t.budget_duration,
         t.budget_reset_at AT TIME ZONE 'UTC'
  FROM "LiteLLM_VerificationToken" t
  ORDER BY t.spend DESC
$fn$;

-- Uso per chiave e modello da `since`: richieste, fallimenti, spesa, token,
-- latenza p50/p95 e p50 del tempo al primo token.
CREATE OR REPLACE FUNCTION jarvis_ro.usage(since timestamptz)
RETURNS TABLE (alias text, model text, requests bigint, failures bigint,
               spend double precision, prompt_tokens bigint, completion_tokens bigint,
               p50_ms double precision, p95_ms double precision, ttft_p50_ms double precision)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  WITH logs AS (
    SELECT s.*,
           coalesce(s.request_duration_ms,
                    extract(epoch FROM s."endTime" - s."startTime") * 1000) AS duration_ms,
           CASE WHEN s."completionStartTime" IS NOT NULL AND s.status = 'success'
                THEN extract(epoch FROM s."completionStartTime" - s."startTime") * 1000 END AS ttft_ms
    FROM "LiteLLM_SpendLogs" s
    WHERE s."startTime" >= (since AT TIME ZONE 'UTC')
  )
  SELECT jarvis_ro.key_label(t.key_alias, t.key_name),
         coalesce(nullif(l.model_group, ''), l.model),
         count(*),
         count(*) FILTER (WHERE l.status = 'failure'),
         sum(l.spend),
         sum(l.prompt_tokens)::bigint,
         sum(l.completion_tokens)::bigint,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.duration_ms),
         percentile_cont(0.95) WITHIN GROUP (ORDER BY l.duration_ms),
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.ttft_ms)
  FROM logs l
  LEFT JOIN "LiteLLM_VerificationToken" t ON t.token = l.api_key
  GROUP BY 1, 2
  ORDER BY 3 DESC
$fn$;

-- Gli ultimi errori: classe, codice e messaggio troncato. Niente traceback,
-- niente richiesta.
CREATE OR REPLACE FUNCTION jarvis_ro.recent_errors(since timestamptz, max_rows integer)
RETURNS TABLE (at timestamptz, alias text, model text, error_class text,
               error_code text, normalized_error text, message text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT s."startTime" AT TIME ZONE 'UTC',
         jarvis_ro.key_label(t.key_alias, t.key_name),
         coalesce(nullif(s.model_group, ''), s.model),
         s.metadata -> 'error_information' ->> 'error_class',
         s.metadata -> 'error_information' ->> 'error_code',
         s.metadata -> 'error_information' ->> 'normalized_error',
         left(s.metadata -> 'error_information' ->> 'error_message', 300)
  FROM "LiteLLM_SpendLogs" s
  LEFT JOIN "LiteLLM_VerificationToken" t ON t.token = s.api_key
  WHERE s.status = 'failure' AND s."startTime" >= (since AT TIME ZONE 'UTC')
  ORDER BY s."startTime" DESC
  LIMIT least(max_rows, 200)
$fn$;

-- Spesa e richieste per giorno e chiave, dagli aggregati giornalieri di LiteLLM.
CREATE OR REPLACE FUNCTION jarvis_ro.daily_spend(days integer)
RETURNS TABLE (day date, alias text, spend double precision, requests bigint, failures bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT d.date::date,
         jarvis_ro.key_label(t.key_alias, t.key_name),
         sum(d.spend),
         sum(d.api_requests)::bigint,
         sum(d.failed_requests)::bigint
  FROM "LiteLLM_DailyUserSpend" d
  LEFT JOIN "LiteLLM_VerificationToken" t ON t.token = d.api_key
  WHERE d.date::date >= current_date - least(days, 90)
  GROUP BY 1, 2
  ORDER BY 1, 2
$fn$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA jarvis_ro FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  jarvis_ro.key_label(text, text),
  jarvis_ro.key_budgets(),
  jarvis_ro.usage(timestamptz),
  jarvis_ro.recent_errors(timestamptz, integer),
  jarvis_ro.daily_spend(integer)
TO jarvis_reader;
