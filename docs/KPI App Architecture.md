Oscar & Co Staff App KPI Architecture, Locked Decisions Log

This note records the product and architecture decisions locked so far for the new Targets and Performance Reporting work in the existing Oscar & Co Staff App.

1. Core structure
1.1 Separate concepts

Keep Targets and Performance as separate concepts.

Targets = what should be achieved
Performance = what actually happened
1.2 Hybrid actuals model

Use a hybrid actuals model, not batch-only actuals.

Current open month operational KPIs should be calculated live from existing sales tables/views via reporting RPCs
Closed historical months can be stored/finalised in kpi_monthly_values
Retention/frequency KPIs should use monthly materialised/finalised calculations
Uploaded KPIs and manual/admin KPIs should flow into stored monthly values
1.3 Targets vs actuals

Targets remain separate from actuals.

1.4 Pacing

For eligible monthly accumulating KPIs, support month-to-date pacing against monthly targets.

target_mtd should be prorated by elapsed calendar days
this should apply only where the KPI meaning supports it
not all KPIs should be paced
2. Scope model

Use scope terminology consistently as:

business
location
staff

Do not use global.

3. KPI naming and locked KPI set
3.1 KPI renamed

The KPI previously discussed as:

apprentice ratio
use of assistants ratio

is now locked as:

Assistant utilisation ratio
3.2 KPI families in scope for stylists, managers, admins

Stylists should be able to see these for themselves. Managers and admins should also be able to see these rolled up for each location and the business overall:

Revenue
Average Client Spend
Assistant utilisation ratio
Guests per month
New clients per month
Client Frequency
Client Retention 6 month
Client Retention 12 month
New Client Retention 6 month
New Client Retention 12 month
Utilisation
Future Utilisation
3.3 Admin-only KPIs

These remain admin only:

EBITDA
Operational Costs
COGS %
Support Staff Cost %
Stock Value

This aligns with the KPI dashboard extract and the admin-entered nature of several of those metrics.

4. Role visibility
4.1 Stylists

Stylists can see the approved KPI set for themselves only.

4.2 Managers

Managers can see:

their own KPIs
each staff member
location rollups
business rollups
4.3 Admins

Admins can see:

everything managers can see
admin-only financial/operational KPIs
4.4 No cross-stylist comparison for stylists

Stylists do not see other stylists’ performance in v1.

5. Self-scope rule

When the approved KPI set is viewed by a stylist, each KPI is based on that stylist’s own client book / own sales / own activity, not the salon overall.

This applies to:

Revenue
Average Client Spend
Assistant utilisation ratio
Guests per month
New clients per month
Client Frequency
Client Retention 6 month
Client Retention 12 month
New Client Retention 6 month
New Client Retention 12 month
Utilisation
Future Utilisation
6. New client and guest identity rules
6.1 Source identity

For now, the client identity basis is:

Customer name
sourced from the original Sales Daily Sheets WHOLE NAME field
6.2 Meaning of guests and new clients
Guests per month = distinct normalised WHOLE NAME in that month
New clients per month = distinct normalised WHOLE NAME in that month with no earlier appearance in the full historical dataset
6.3 New client definition

A new client means:

first time ever seen in the full dataset

Not rolling lookback.

6.4 Intended visibility

This identity model is acceptable for:

manager/admin reporting

It should be treated cautiously for stylist-facing reporting until validated, because it is a best-effort identity model.

The dashboard extract explicitly defines new clients as clients appearing for the first time in the dataset provided.

7. Customer name normalisation rules

For guest identity in KPI calculations, use a normalised form of WHOLE NAME.

7.1 Apply in this order
Truncate from the first ( onward
Example: Ashley Smythe (75) → Ashley Smythe
Example: Colleen Clapshaw (A) → Colleen Clapshaw
Example: Zara Ellis (comp winner) → Zara Ellis
Truncate from the first standalone numeric suffix onward
Example: Alice Vermunt 60 → Alice Vermunt
Example: Rachael Hausman 60 A → Rachael Hausman
If the remaining name ends with a standalone trailing A, B, or C, remove it
Example: Christine Ridley C → Christine Ridley
Example: Kanika Jhamb B → Kanika Jhamb
Collapse repeated spaces
Trim
Lowercase
7.2 Known limitation

Do not try to handle the rare middle-parenthesis preferred-name case in v1, for example:

Savannagh (Mari) Primrose

This may be over-normalised in v1 and is accepted as a known limitation due to very low occurrence.

7.3 Raw vs normalised

Keep both:

raw customer name
normalised customer name

Do not overwrite the raw source value.

8. Assistant utilisation ratio
8.1 Meaning

For KPI purposes:

assistant = apprentice

The KPI is locked as:

Assistant utilisation ratio
8.2 KPI definition

Assistant utilisation ratio = assistant-helped sales ex GST / total eligible sales ex GST

8.3 Scope

Calculate:

per stylist
then location rollup
then business rollup
8.4 Existing schema basis

This KPI should reuse the existing assistant redirect logic already present in the payroll/commission model, rather than introducing a separate apprentice classification rule.

The strongest existing schema concept is:

assistant_redirect_candidate in v_sales_transactions_enriched
8.5 Plain English meaning of assistant redirect candidate

Assistant redirect candidate means:

This sales line looks like work that was physically done by an assistant, but the commercial ownership of the line should be credited to the main stylist rather than the assistant.

8.6 Current schema rule

A row is considered an assistant redirect candidate when all of these are true:

staff_work_id exists
staff_paid_id exists
staff_work_id <> staff_paid_id
staff_work_primary_role = 'assistant'
staff_work_remuneration_plan = 'wage'

This logic is already present in v_sales_transactions_enriched.

8.7 Existing commercial redirect behaviour

When assistant_redirect_candidate is true, the commission owner is redirected to the paid staff member using:

commission_owner_candidate_id = staff_paid_id
commission_owner_rule = 'assistant_work_redirected_to_paid_staff'
8.8 Further downstream use

The assistant-aware logic continues in v_commission_calculations_core, including fields such as:

commission_can_use_assistants
assistant_usage_alert_derived
assistant_commission_amt_ex_gst

assistant_commission_amt_ex_gst is only populated when:

work role is assistant
assistant usage is allowed
price and commission rate are present
8.9 Source flow

The existing pipeline is:

Sales Daily Sheets
→ sales_daily_sheets_staged_rows
→ apply_sales_daily_sheets_to_payroll
→ raw_sales_import_rows
→ load_raw_sales_rows_to_transactions
→ sales_transactions
→ v_sales_transactions_enriched
→ v_commission_calculations_core
→ final payroll / commission reporting views

9. Stylist profitability
9.1 Locked formula basis

Stylist profitability = total sales for stylist / staff_members.fte

9.2 FTE source

The intended default FTE source is:

staff_members.fte

Do not assume manual FTE entry for this KPI.

9.3 What not to use

Do not use staff_capacity_monthly as the default FTE source for stylist profitability.

staff_capacity_monthly is reserved for capacity/utilisation-related use cases unless a later proven gap requires otherwise. This is consistent with the reviewed migration summary that called out staff_members.fte as the intended default source.

10. Utilisation and Future Utilisation upload contract
10.1 Source and ownership

These reports are:

uploaded by the salon manager
one file per location
currently for Orewa and Takapuna
same report structure for both KPI types
differentiated by upload workflow and date range meaning, not by file structure
10.2 Upload types
Utilisation
uploaded on or around the first day of the month
represents the previous month
Future Utilisation
uploaded every Friday
represents the following week
10.3 KPI value

For both KPI types, the KPI value is:

Percent Utilisation
10.4 File grain

Treat the file as:

one file per location
staff-level rows within that location
plus an 00-Overall Totals row that is not canonical
10.5 Canonical source rows

Use:

the individual staff rows as source of truth

Do not rely on:

00-Overall Totals as the canonical KPI fact
10.6 Matching rule

Match uploaded name to:

staff_members.display_name

Skip:

blank names
totals rows such as 00-Overall Totals
10.7 Columns to capture

Capture these fields for each staff row:

name
Working hours
Billable Appointments
Admin stuff
PAID LEAVE
UNPAID LEAVE
percent Billable
Percent Utilisation

Do not bring through:

PAID CUSTOM
APPTS ON CUST TIME
UNPAID CUSTOM
10.8 Storage intent

Store:

one row per staff member per upload
scope = staff
rollups to location and business derived later from staff rows

This matches the uploaded report shape and the user’s decision to preserve useful non-KPI staff-level monthly metrics from the same upload.

11. Data architecture direction
11.1 Canonical stored monthly facts

Keep a stored monthly KPI values layer for:

closed/finalised historical months
retention/frequency KPI snapshots
uploaded KPI outputs
manual/admin KPI outputs
hybrid/derived KPI outputs where appropriate
11.2 Not source of truth for open month live operational KPIs

kpi_monthly_values should not be the primary source of truth for current open month live operational KPIs. That intent was explicitly captured in the reviewed architecture proposal.

11.3 Raw vs resolved sources

Retain separate source-specific tables before promotion into canonical KPI facts:

manual inputs
upload batches / rows
targets
monthly values
12. Admin-only manual/financial KPI treatment

These remain admin-only and should be treated as manual or admin-entered unless a reliable future source is confirmed:

EBITDA
Operational Costs
COGS %
Support Staff Cost %
Stock Value

This matches both the KPI extract and the reviewed migration notes that identified several of these as manual/admin-populated.

13. Validation expectations before broad exposure

The following KPI candidates should be explicitly validated before broad stylist-facing exposure:

Revenue
Guests per month
New clients per month
Average Client Spend
Retail %

The reviewed architecture notes explicitly called these out as requiring validation, especially because of live calculation and name-based customer identity risk.

14. Build sequencing intent

Before the next implementation prompt, the intent is:

lock business rules first
then generate a clean Opus prompt
do not move into UI prematurely

Read-side and structural/backend-first work remain the priority.

15. Open items intentionally not yet locked

These remain outside the locked decisions set unless later added:

exact UI layout
write RPC scope and timing
stretch target behaviour in UI
middle-parenthesis customer-name refinement beyond v1
any future guest ID pipeline
any future month-varying FTE override model

If you want, next I’ll turn this into a shorter copy-paste version for your project notes / Cursor context.