/**
 * Sales Daily Sheets import — called synchronously from Postgres via `extensions.http_post`
 * (see migration 20260412230000_sales_daily_sheets_import_pipeline.sql).
 *
 * Secrets: set INTERNAL_IMPORT_SECRET in Edge secrets to match DB `app.internal_import_secret`.
 * Standard Supabase Edge env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8"
import Papa from "https://esm.sh/papaparse@5.4.1"

const BUCKET = "sales-daily-sheets"

type ImportBody = {
  batch_id: string
  storage_path: string
  internal_secret: string
  /** When set, applied to every staged row (from Admin Imports). */
  location_id?: string
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

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ ok: false, error: "Method not allowed" }, { status: 405 })
  }

  let body: ImportBody
  try {
    body = (await req.json()) as ImportBody
  } catch {
    return Response.json({ ok: false, error: "Invalid JSON" }, { status: 400 })
  }

  const expected = Deno.env.get("INTERNAL_IMPORT_SECRET")
  if (!expected || body.internal_secret !== expected) {
    return Response.json({ ok: false, error: "Unauthorized" }, { status: 401 })
  }

  if (!body.batch_id || !body.storage_path) {
    return Response.json({ ok: false, error: "batch_id and storage_path required" }, {
      status: 400,
    })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceKey) {
    return Response.json({ ok: false, error: "Missing Supabase env" }, { status: 500 })
  }

  const supabase = createClient(supabaseUrl, serviceKey)

  const { data: dl, error: dlErr } = await supabase.storage
    .from(BUCKET)
    .download(body.storage_path)

  if (dlErr || !dl) {
    return Response.json(
      { ok: false, error: dlErr?.message ?? "Download failed" },
      { status: 500 },
    )
  }

  const text = await dl.text()
  const parsed = Papa.parse<Record<string, string>>(text, {
    header: true,
    skipEmptyLines: "greedy",
  })

  if (parsed.errors.length > 0 && parsed.data.length === 0) {
    return Response.json(
      { ok: false, error: parsed.errors.map((e) => e.message).join("; ") },
      { status: 400 },
    )
  }

  const records = parsed.data.filter((r) => Object.keys(r).some((k) => String(r[k] ?? "").trim() !== ""))

  if (records.length === 0) {
    return Response.json({ ok: false, error: "No data rows in CSV" }, { status: 400 })
  }

  const { error: delErr } = await supabase
    .from("sales_daily_sheets_staged_rows")
    .delete()
    .eq("batch_id", body.batch_id)

  if (delErr) {
    return Response.json({ ok: false, error: delErr.message }, { status: 500 })
  }

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
    const forcedLocation =
      body.location_id && UUID_RE.test(body.location_id) ? body.location_id : null

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

  const chunk = 300
  for (let i = 0; i < rowsToInsert.length; i += chunk) {
    const slice = rowsToInsert.slice(i, i + chunk)
    const { error: insErr } = await supabase.from("sales_daily_sheets_staged_rows").insert(slice)
    if (insErr) {
      return Response.json({ ok: false, error: insErr.message }, { status: 500 })
    }
  }

  return Response.json({
    ok: true,
    rows_inserted: rowsToInsert.length,
  })
})
