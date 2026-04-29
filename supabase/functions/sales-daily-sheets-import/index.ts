/**
 * Sales Daily Sheets import — invoked from the browser with JWT or with INTERNAL_IMPORT_SECRET.
 * Heavy work runs in EdgeRuntime.waitUntil so the HTTP response returns immediately (202);
 * the client polls sales_daily_sheets_import_batches for completion (avoids long-held invoke/fetch).
 *
 * Memory model
 * ------------
 * The CSV is processed STREAMING. We never materialise the full file as
 * a string and we never build a full `records` or `rowsToInsert`
 * array. Instead we:
 *   1. Pipe `dl.stream()` through `TextDecoderStream`.
 *   2. Run a tiny custom CSV parser (`parseCsvStream`) that yields one
 *      row of cells at a time, properly handling RFC-4180-style quoted
 *      fields with embedded commas, quotes (`""`), and newlines.
 *   3. Map each row to its staged-row shape and push it into a bounded
 *      buffer of size `STAGED_INSERT_CHUNK_SIZE`. When the buffer is
 *      full we flush via `insert_sales_daily_sheets_staged_rows_chunk`
 *      and clear the buffer.
 *
 * This keeps peak memory bounded by `STAGED_INSERT_CHUNK_SIZE` mapped
 * rows + a small parser buffer (a few decoded chunks of the source
 * blob), regardless of how large the CSV is. The previous flow held
 * the whole CSV text + parsed Papa records + filtered records + mapped
 * `rowsToInsert` array all in memory at once and tipped the 269 MB
 * Edge memory ceiling for larger files.
 *
 * Everything else (batch status flow, RPC names, auth rules,
 * cleanup_storage_only behaviour, CORS, request body shape) is
 * preserved verbatim.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8"

const BUCKET = "sales-daily-sheets"

/** Same as `@supabase/supabase-js` `corsHeaders` — required for browser `functions.invoke` + preflight. */
const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-retry-count",
  "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
}

type ImportBody = {
  batch_id: string
  storage_path: string
  internal_secret?: string
  /** Required for normal import (Admin). */
  location_id?: string
  /**
   * When true, only runs Storage API removal for `storage_path`.
   * Requires internal_secret (same as before).
   */
  cleanup_storage_only?: boolean
}

function normHeader(s: string): string {
  return s.trim().toLowerCase().replace(/\s+/g, " ")
}

function pick(row: Record<string, string>, ...keys: string[]): string | undefined {
  const lower = new Map<string, string>()
  for (const [k, v] of Object.entries(row)) {
    lower.set(normHeader(k), v)
  }
  for (const key of keys) {
    const v = lower.get(normHeader(key))
    if (v !== undefined && String(v).trim() !== "") return String(v)
  }
  return undefined
}

function parseNum(s: string | undefined): number | null {
  if (s == null || s === "") return null
  const n = Number(String(s).replace(/[^0-9.-]/g, ""))
  return Number.isFinite(n) ? n : null
}

function parseDate(s: string | undefined): string | null {
  if (s == null || s === "") return null
  const t = s.trim()
  if (/^\d{4}-\d{2}-\d{2}/.test(t)) return t.slice(0, 10)
  const d = new Date(t)
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString().slice(0, 10)
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

function msSince(t0: number): number {
  return Math.round(performance.now() - t0)
}

/** Structured timing logs for observability only (prefix: sds_timing). */
function logEdgeTiming(payload: Record<string, unknown>): void {
  console.log(JSON.stringify({ tag: "sds_timing_edge", ...payload }))
}

/**
 * Streaming CSV parser. Consumes a UTF-8 byte stream and yields one
 * row's worth of cell strings at a time. Handles RFC-4180-style quoted
 * fields with embedded `,`, `\n`, `\r\n`, and escaped quotes (`""`).
 * The internal text buffer is compacted as rows are consumed so peak
 * memory stays bounded by the size of the largest single row plus a
 * small read-ahead window — never the whole file.
 *
 * Tolerant by design: malformed CSV does not throw; trailing
 * whitespace-only rows just yield empty arrays which the caller can
 * skip. This matches the previous Papa-based behaviour where
 * `skipEmptyLines: "greedy"` quietly dropped blank rows.
 *
 * Strips a leading UTF-8 BOM (`\uFEFF`) if present so the first
 * header cell is not silently mis-keyed.
 */
async function* parseCsvStream(
  byteStream: ReadableStream<Uint8Array>,
): AsyncGenerator<string[]> {
  const reader = byteStream
    .pipeThrough(new TextDecoderStream("utf-8"))
    .getReader()

  let buf = ""
  let pos = 0
  let eof = false
  let strippedBom = false

  // Pull more text from the stream when we don't have at least
  // `need` characters available beyond `pos`. Compacts `buf` after
  // each pull so processed prefix doesn't accumulate.
  const ensure = async (need: number): Promise<void> => {
    while (!eof && buf.length - pos < need) {
      const r = await reader.read()
      if (r.done) {
        eof = true
        return
      }
      let chunk = r.value
      if (!strippedBom) {
        if (chunk.length > 0 && chunk.charCodeAt(0) === 0xfeff) {
          chunk = chunk.slice(1)
        }
        strippedBom = true
      }
      // Drop processed prefix; keep only the unread tail + new chunk.
      if (pos > 0) {
        buf = buf.slice(pos) + chunk
        pos = 0
      } else {
        buf += chunk
      }
    }
  }

  let row: string[] = []
  let field = ""
  let inQuotes = false

  while (true) {
    // Two-character lookahead lets us correctly distinguish `""`
    // (escaped quote inside a quoted field) from `"` (end of field)
    // and `\r\n` from a lone `\r`.
    await ensure(2)

    if (pos >= buf.length) {
      // EOF — flush any half-built field/row.
      if (inQuotes || field.length > 0 || row.length > 0) {
        row.push(field)
        yield row
      }
      return
    }

    const ch = buf.charCodeAt(pos)

    if (inQuotes) {
      if (ch === 34 /* " */) {
        if (pos + 1 < buf.length && buf.charCodeAt(pos + 1) === 34) {
          field += '"'
          pos += 2
        } else {
          inQuotes = false
          pos += 1
        }
      } else {
        field += buf[pos]
        pos += 1
      }
      continue
    }

    if (ch === 34 /* " */) {
      inQuotes = true
      pos += 1
    } else if (ch === 44 /* , */) {
      row.push(field)
      field = ""
      pos += 1
    } else if (ch === 10 /* \n */) {
      row.push(field)
      field = ""
      yield row
      row = []
      pos += 1
    } else if (ch === 13 /* \r */) {
      row.push(field)
      field = ""
      yield row
      row = []
      pos += 1
      if (pos < buf.length && buf.charCodeAt(pos) === 10) {
        pos += 1
      }
    } else {
      field += buf[pos]
      pos += 1
    }
  }
}

async function authorizeRequest(
  req: Request,
  body: ImportBody,
): Promise<{ ok: boolean; userId?: string; internal?: boolean }> {
  const expected = Deno.env.get("INTERNAL_IMPORT_SECRET")
  if (expected && body.internal_secret === expected) {
    return { ok: true, internal: true }
  }

  const authHeader = req.headers.get("Authorization")
  if (!authHeader?.trim().startsWith("Bearer ")) {
    return { ok: false }
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  if (!supabaseUrl || !anonKey) {
    return { ok: false }
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  })

  const { error: rpcErr } = await userClient.rpc("list_active_locations_for_import")
  if (rpcErr) {
    return { ok: false }
  }

  const { data: { user }, error: userErr } = await userClient.auth.getUser()
  if (userErr || !user) {
    return { ok: false }
  }

  return { ok: true, userId: user.id }
}

/**
 * Map a single raw CSV record into the staged-row shape consumed by
 * `insert_sales_daily_sheets_staged_rows_chunk`. Pulled out so the
 * streaming loop can call it once per row without keeping a giant
 * mapped array around. Customer name prefers WHOLE_NAME (Kitomba);
 * staff paid display must not use WHOLE_NAME / NAME / FIRST_NAME.
 */
function mapRowToStagedRow(args: {
  row: Record<string, string>
  lineNumber: number
  batchId: string
  forcedLocation: string
}): Record<string, unknown> {
  const { row, lineNumber, batchId, forcedLocation } = args

  const invoice = pick(
    row,
    "invoice",
    "invoice #",
    "invoice_no",
    "invoice number",
    "source_document_number",
    "SOURCE_DOCUMENT_NUMBER",
  )
  const saleDate = pick(row, "sale date", "sale_date", "date")
  const payWeekStart = pick(row, "pay week start", "pay_week_start")
  const payWeekEnd = pick(row, "pay week end", "pay_week_end")
  const payDate = pick(row, "pay date", "pay_date")
  const customerName = pick(
    row,
    "WHOLE_NAME",
    "whole_name",
    "customer",
    "customer name",
    "customer_name",
  )
  const productService = pick(
    row,
    "product service name",
    "product_service_name",
    "service",
    "product",
  )
  const quantity = pick(row, "quantity", "qty")
  const priceExGst = pick(row, "price ex gst", "price_ex_gst", "price ex gst ($)", "price")
  const staffPaid = pick(
    row,
    "derived_staff_paid_display_name",
    "staff paid",
    "stylist",
    "staff",
  )
  const actualComm = pick(
    row,
    "actual_commission_amount",
    "actual commission",
    "commission",
  )
  const asstComm = pick(row, "assistant_commission_amount", "assistant commission")
  const payrollStatus = pick(row, "payroll status", "payroll_status")
  const stylistNote = pick(row, "stylist visible note", "stylist_visible_note", "note")
  const locationId = pick(row, "location_id", "location id")

  return {
    batch_id: batchId,
    line_number: lineNumber,
    invoice: invoice ?? null,
    sale_date: saleDate ?? null,
    pay_week_start: parseDate(payWeekStart),
    pay_week_end: parseDate(payWeekEnd),
    pay_date: parseDate(payDate),
    customer_name: customerName ?? null,
    product_service_name: productService ?? null,
    quantity: parseNum(quantity),
    price_ex_gst: parseNum(priceExGst),
    derived_staff_paid_display_name: staffPaid ?? null,
    actual_commission_amount: parseNum(actualComm),
    assistant_commission_amount: parseNum(asstComm),
    payroll_status: payrollStatus ?? null,
    stylist_visible_note: stylistNote ?? null,
    location_id:
      forcedLocation ??
      (locationId && UUID_RE.test(locationId) ? locationId : null),
    extras: row as unknown as Record<string, unknown>,
  }
}

async function processSalesDailySheetsImport(args: {
  body: ImportBody
  supabaseUrl: string
  serviceKey: string
}): Promise<void> {
  const { body, supabaseUrl, serviceKey } = args
  const supabase = createClient(supabaseUrl, serviceKey)
  const tRun0 = performance.now()

  const failBatch = async (msg: string) => {
    await supabase
      .from("sales_daily_sheets_import_batches")
      .update({
        status: "failed",
        message: "Import failed",
        error_message: msg.slice(0, 4000),
      })
      .eq("id", body.batch_id)
  }

  let t0 = performance.now()
  const { data: dl, error: dlErr } = await supabase.storage
    .from(BUCKET)
    .download(body.storage_path)
  const ms_storage_download = msSince(t0)

  if (dlErr || !dl) {
    await failBatch(dlErr?.message ?? "Download failed")
    return
  }

  t0 = performance.now()
  const { error: delErr } = await supabase.rpc(
    "delete_sales_daily_sheets_staged_rows_for_batch",
    { p_batch_id: body.batch_id },
  )

  if (delErr) {
    await failBatch(delErr.message)
    return
  }

  const ms_staged_row_delete = msSince(t0)

  const forcedLocation = body.location_id!

  // Balance: larger chunks = fewer round trips; very large single INSERTs can hit statement_timeout on Postgres.
  const STAGED_INSERT_CHUNK_SIZE = 500

  let headers: string[] | null = null
  let lineNumber = 0
  let nStaged = 0
  let buffer: Record<string, unknown>[] = []
  let ms_staged_row_insert_total = 0

  const flushBuffer = async (): Promise<{ ok: boolean; err?: string }> => {
    if (buffer.length === 0) return { ok: true }
    const tIns = performance.now()
    const { error: insErr } = await supabase.rpc(
      "insert_sales_daily_sheets_staged_rows_chunk",
      { p_rows: buffer },
    )
    ms_staged_row_insert_total += msSince(tIns)
    if (insErr) {
      console.error("sds_timing_edge staged_insert_chunk_failed", {
        tag: "sds_timing_edge",
        batch_id: body.batch_id,
        chunk_first_line_number: buffer[0]?.line_number,
        chunk_len: buffer.length,
        error: insErr.message,
      })
      return { ok: false, err: insErr.message }
    }
    nStaged += buffer.length
    buffer = []
    return { ok: true }
  }

  // ms_stream_and_stage measures wall-clock time spent in the
  // stream/parse/map loop INCLUDING the chunk-insert RPCs that fire
  // inside it. ms_staged_row_insert is then tracked separately so we
  // can see the parse-only fraction implicitly (= total - insert).
  t0 = performance.now()
  try {
    const byteStream = dl.stream()
    for await (const fields of parseCsvStream(byteStream)) {
      // Header row first.
      if (headers === null) {
        headers = fields.map((h) => h ?? "")
        continue
      }

      // skipEmptyLines: "greedy" — drop rows whose every cell is blank.
      let allBlank = true
      for (const f of fields) {
        if (f != null && String(f).trim() !== "") {
          allBlank = false
          break
        }
      }
      if (allBlank) continue

      lineNumber += 1

      // Re-key into the Record<string, string> shape `pick()` expects.
      // Extra trailing fields beyond the header row get dropped, matching
      // the previous Papa `header: true` behaviour.
      const row: Record<string, string> = {}
      const cols = Math.min(headers.length, fields.length)
      for (let i = 0; i < cols; i += 1) {
        row[headers[i]] = fields[i] ?? ""
      }

      const staged = mapRowToStagedRow({
        row,
        lineNumber,
        batchId: body.batch_id,
        forcedLocation,
      })
      buffer.push(staged)

      if (buffer.length >= STAGED_INSERT_CHUNK_SIZE) {
        const flush = await flushBuffer()
        if (!flush.ok) {
          await failBatch(flush.err ?? "Staged chunk insert failed")
          return
        }
      }
    }

    // Flush the final partial chunk.
    const finalFlush = await flushBuffer()
    if (!finalFlush.ok) {
      await failBatch(finalFlush.err ?? "Staged chunk insert failed")
      return
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    console.error("sds_timing_edge stream_parse_failed", {
      tag: "sds_timing_edge",
      batch_id: body.batch_id,
      line_number: lineNumber,
      error: msg,
    })
    await failBatch(`CSV parse failed: ${msg}`)
    return
  }
  const ms_stream_and_stage = msSince(t0)

  if (headers === null) {
    await failBatch("CSV is empty")
    return
  }
  if (nStaged === 0) {
    await failBatch("No data rows in CSV")
    return
  }

  t0 = performance.now()
  const { error: applyErr } = await supabase.rpc("apply_sales_daily_sheets_to_payroll", {
    p_batch_id: body.batch_id,
  })
  const ms_apply_sales_daily_sheets_to_payroll_rpc = msSince(t0)

  if (applyErr) {
    await failBatch(applyErr.message)
    return
  }

  t0 = performance.now()
  const { data: afterBatch, error: afterErr } = await supabase
    .from("sales_daily_sheets_import_batches")
    .select("rows_loaded")
    .eq("id", body.batch_id)
    .single()

  if (afterErr) {
    await failBatch(afterErr.message)
    return
  }

  const rowsLoaded = afterBatch?.rows_loaded ?? nStaged

  const { error: doneErr } = await supabase
    .from("sales_daily_sheets_import_batches")
    .update({
      status: "completed",
      message: "Import completed",
      rows_staged: nStaged,
      rows_loaded: rowsLoaded,
      error_message: null,
    })
    .eq("id", body.batch_id)

  const ms_final_batch_select_and_update = msSince(t0)

  if (doneErr) {
    console.error("sales-daily-sheets-import: final batch update failed", doneErr)
  }

  logEdgeTiming({
    batch_id: body.batch_id,
    row_count: nStaged,
    ms_storage_download,
    ms_staged_row_delete,
    ms_stream_and_stage,
    ms_staged_row_insert: ms_staged_row_insert_total,
    ms_apply_sales_daily_sheets_to_payroll_rpc,
    ms_final_batch_select_and_update,
    ms_process_total: msSince(tRun0),
  })
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders })
  }

  if (req.method !== "POST") {
    return Response.json({ ok: false, error: "Method not allowed" }, {
      status: 405,
      headers: corsHeaders,
    })
  }

  let body: ImportBody
  try {
    body = (await req.json()) as ImportBody
  } catch {
    return Response.json({ ok: false, error: "Invalid JSON" }, {
      status: 400,
      headers: corsHeaders,
    })
  }

  const auth = await authorizeRequest(req, body)
  if (!auth.ok) {
    return Response.json({ ok: false, error: "Unauthorized" }, {
      status: 401,
      headers: corsHeaders,
    })
  }

  if (!body.batch_id || !body.storage_path) {
    return Response.json({ ok: false, error: "batch_id and storage_path required" }, {
      status: 400,
      headers: corsHeaders,
    })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceKey) {
    return Response.json({ ok: false, error: "Missing Supabase env" }, {
      status: 500,
      headers: corsHeaders,
    })
  }

  const supabase = createClient(supabaseUrl, serviceKey)

  if (body.cleanup_storage_only === true) {
    if (!auth.internal) {
      return Response.json({ ok: false, error: "Unauthorized" }, {
        status: 401,
        headers: corsHeaders,
      })
    }
    const { error: rmErr } = await supabase.storage.from(BUCKET).remove([body.storage_path])
    if (rmErr) {
      return Response.json({ ok: false, error: rmErr.message }, {
        status: 500,
        headers: corsHeaders,
      })
    }
    return Response.json({ ok: true, cleanup_removed: true }, { headers: corsHeaders })
  }

  if (!body.location_id || !UUID_RE.test(body.location_id)) {
    return Response.json({ ok: false, error: "location_id (uuid) required" }, {
      status: 400,
      headers: corsHeaders,
    })
  }

  const { data: batchRow, error: batchErr } = await supabase
    .from("sales_daily_sheets_import_batches")
    .select("id, storage_path, selected_location_id, created_by, status")
    .eq("id", body.batch_id)
    .maybeSingle()

  if (batchErr || !batchRow) {
    return Response.json({ ok: false, error: "Batch not found" }, {
      status: 404,
      headers: corsHeaders,
    })
  }

  if (batchRow.storage_path !== body.storage_path) {
    return Response.json({ ok: false, error: "storage_path does not match batch" }, {
      status: 400,
      headers: corsHeaders,
    })
  }

  if (batchRow.selected_location_id !== body.location_id) {
    return Response.json({ ok: false, error: "location_id does not match batch" }, {
      status: 400,
      headers: corsHeaders,
    })
  }

  if (!auth.internal && auth.userId && batchRow.created_by && batchRow.created_by !== auth.userId) {
    return Response.json({ ok: false, error: "Forbidden" }, {
      status: 403,
      headers: corsHeaders,
    })
  }

  const { error: procErr } = await supabase
    .from("sales_daily_sheets_import_batches")
    .update({
      status: "processing",
      message: "Import in progress (Edge)",
      error_message: null,
    })
    .eq("id", body.batch_id)

  if (procErr) {
    return Response.json({ ok: false, error: procErr.message }, {
      status: 500,
      headers: corsHeaders,
    })
  }

  EdgeRuntime.waitUntil(
    processSalesDailySheetsImport({ body, supabaseUrl, serviceKey }).catch((e) => {
      console.error("sales-daily-sheets-import background:", e)
    }),
  )

  return new Response(JSON.stringify({ ok: true, accepted: true }), {
    status: 202,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
})
