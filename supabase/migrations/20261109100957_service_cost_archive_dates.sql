BEGIN;

ALTER TABLE public.service_product_cost_services ADD COLUMN archived_at timestamptz;
COMMENT ON COLUMN public.service_product_cost_services.archived_at IS
 'Server-recorded time of the current archive. NULL for active services and legacy archives whose date was not recorded. No historical date is inferred.';
ALTER TABLE public.service_product_cost_services ADD CONSTRAINT active_service_has_no_archive_date
 CHECK (NOT is_active OR archived_at IS NULL);

CREATE FUNCTION private.record_service_product_archive_date()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.is_active THEN
  NEW.archived_at:=NULL;
 ELSIF OLD.is_active THEN
  NEW.archived_at:=statement_timestamp();
 ELSE
  -- Repeating an archive request does not change its original date, and
  -- an old unknown date must not be replaced with today's date.
  NEW.archived_at:=OLD.archived_at;
 END IF;
 RETURN NEW;
END $$;
ALTER FUNCTION private.record_service_product_archive_date() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.record_service_product_archive_date() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER record_service_product_archive_date BEFORE UPDATE ON public.service_product_cost_services
 FOR EACH ROW EXECUTE FUNCTION private.record_service_product_archive_date();

-- Preserve the existing discovery, date lookup, permissions and return fields.
-- The private implementation cannot be called through the public Data API.
ALTER FUNCTION public.get_service_product_costs(date) SET SCHEMA private;
ALTER FUNCTION private.get_service_product_costs(date) RENAME TO get_service_product_costs_without_archive_date;
REVOKE ALL ON FUNCTION private.get_service_product_costs_without_archive_date(date) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.get_service_product_costs(p_as_of date DEFAULT current_date)
RETURNS TABLE(service_id uuid,service_name text,is_active boolean,unit_cost_ex_gst numeric,
 effective_from date,effective_to date,seen_in_sales boolean,last_sale_date date,first_sale_date date,
 source_product_ids text[],location_names text[],classification_labels text[],archived_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT original.*,s.archived_at
 FROM private.get_service_product_costs_without_archive_date(p_as_of) original
 JOIN public.service_product_cost_services s ON s.id=original.service_id;
$$;
ALTER FUNCTION public.get_service_product_costs(date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_service_product_costs(date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_service_product_costs(date) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
