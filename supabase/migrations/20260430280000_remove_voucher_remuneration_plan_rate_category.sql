-- Remove `voucher` from remuneration_plan_rates: voucher sales use `no_commission_voucher`
-- in commission views, not this plan-rate key. Clean up data, constraint, and staging column.

DELETE FROM public.remuneration_plan_rates
WHERE commission_category = 'voucher';

ALTER TABLE public.remuneration_plan_rates
  DROP CONSTRAINT IF EXISTS remuneration_plan_rates_category_valid;

ALTER TABLE public.remuneration_plan_rates
  ADD CONSTRAINT remuneration_plan_rates_category_valid CHECK (
    commission_category = ANY (
      ARRAY[
        'retail_product',
        'professional_product',
        'service',
        'toner_with_other_service',
        'extensions_product',
        'extensions_service'
      ]::text[]
    )
  );

ALTER TABLE public.stg_dimremunerationplans
  DROP COLUMN IF EXISTS voucher;
