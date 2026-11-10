# Contractor invoice calculations

New contractor invoice previews show eligible sales, product cost, commissionable amount and contractor fee, excluding GST. The source invoice drilldown shows each item's actual rate and distinguishes excluded items from eligible sales. Customer invoice totals include excluded items; eligible sales do not.

The weekly payroll subtotal is authoritative. Customer group fees are displayed rounded to cents; any difference from rounding the weekly raw commission once is shown as a separate rounding adjustment. GST is calculated once on the reconciled subtotal.

Version 2 invoices capture the complete calculation and source detail at creation. Saved invoice screens and printed PDFs use those snapshots. Existing invoices keep their original amounts and source payloads; older records explicitly explain when calculation detail was not captured. Their source-sale drilldown remains available without inventing historical deductions.

The new public RPC wrappers are invoker functions. Private implementations enforce authenticated contractor-invoice page permissions, use an empty search path and disable JIT. Older RPCs remain available for compatibility; the updated app uses version 2 preview and creation endpoints.

Validation: `scripts/local/invoice-calculation-tests.sql` runs inside a rollback-only transaction against the local Docker database. It covers mixed rates, deductions, excluded items, rounding, immutable snapshots, existing invoice preservation and access denial. Browser checks covered live previews, new and legacy saved invoices, nested dialogs, 320px and 390px screens, and A4 PDF rendering. No production invoices were created for testing.
