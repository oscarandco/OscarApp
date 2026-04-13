/**
 * Sales Daily Sheets import — invoked from the browser with JWT or with INTERNAL_IMPORT_SECRET.
 * Heavy work runs in EdgeRuntime.waitUntil so the HTTP response returns immediately (202);
 * the client polls sales_daily_sheets_import_batches for completion (avoids long-held invoke/fetch).
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8"
import Papa from "https://esm.sh/papaparse@5.4.1"

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
  const text = await dl.text()
  const ms_blob_text = msSince(t0)

  t0 = performance.now()
  const parsed = Papa.parse<Record<string, string>>(text, {
    header: true,
    skipEmptyLines: "greedy",
  })

  if (parsed.errors.length > 0 && parsed.data.length === 0) {
    const msg = parsed.errors.map((e) => e.message).join("; ")
    await failBatch(msg)
    return
  }

  const records = parsed.data.filter((r) =>
    Object.keys(r).some((k) => String(r[k] ?? "").trim() !== ""),
  )

  if (records.length === 0) {
    await failBatch("No data rows in CSV")
    return
  }

  const ms_csv_parse = msSince(t0)

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

  t0 = performance.now()
  const rowsToInsert = records.map((row, idx) => {
    const invoice = pick(row, "invoice", "invoice #", "invoice_no", "invoice number")
    const saleDate = pick(row, "sale date", "sale_date", "date")
    const payWeekStart = pick(row, "pay week start", "pay_week_start")
    const payWeekEnd = pick(row, "pay week end", "pay_week_end")
    const payDate = pick(row, "pay date", "pay_date")
    const customerName = pick(row, "customer", "customer name", "customer_name")
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
      batch_id: body.batch_id,
      line_number: idx + 1,
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
  })

  const ms_csv_map_rows = msSince(t0)

  t0 = performance.now()
  // Balance: larger chunks = fewer round trips; very large single INSERTs can hit statement_timeout on Postgres.
  const STAGED_INSERT_CHUNK_SIZE = 500
  for (let i = 0; i < rowsToInsert.length; i += STAGED_INSERT_CHUNK_SIZE) {
    const slice = rowsToInsert.slice(i, i + STAGED_INSERT_CHUNK_SIZE)
    const { error: insErr } = await supabase.rpc(
      "insert_sales_daily_sheets_staged_rows_chunk",
      { p_rows: slice },
    )
    if (insErr) {
      console.error("sds_timing_edge staged_insert_chunk_failed", {
        tag: "sds_timing_edge",
        batch_id: body.batch_id,
        chunk_start_row: i,
        chunk_len: slice.length,
        error: insErr.message,
      })
      await failBatch(insErr.message)
      return
    }
  }

  const ms_staged_row_insert = msSince(t0)

  const nStaged = rowsToInsert.length

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
    ms_blob_text,
    ms_csv_parse,
    ms_staged_row_delete,
    ms_csv_map_rows,
    ms_staged_row_insert,
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
